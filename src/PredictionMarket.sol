// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOracle} from "./interface/IOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {SortTokens} from "./lib/SortTokens.sol";
import {IPredictionMarket} from "./interface/IPredictionMarket.sol";
import {CentralisedOracle} from "./CentralisedOracle.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PredictionMarketHook} from "./PredictionMarketHook.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// @dev - Anyone extending this contract needs to be a Hook
// TODO: Move hook related functions out of this contract
abstract contract PredictionMarket is IPredictionMarket {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Events
    event MarketCreated(bytes32 indexed marketId, address creator);
    event EventCreated(bytes32 indexed eventId);
    event MarketResolved(bytes32 indexed marketId, int256 outcome);

    // Constants
    int24 public constant TICK_SPACING = 10;
    uint24 public constant FEE = 0; // 0% fee
    bytes public constant ZERO_BYTES = "";

    Currency public immutable usdm;
    IPoolManager private immutable manager;

    // Mappings
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Event) public events;
    mapping(address => bytes32[]) public userMarkets;

    // Store mapping of poolId to poolKey
    mapping(PoolId poolId => PoolKey) public poolKeys;
    mapping(PoolId poolId => IPoolManager.ModifyLiquidityParams) public providedLiquidity;

    // Pool Manager calls this, during .unlock()
    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
    }

    constructor(Currency _usdm, IPoolManager _poolManager) {
        usdm = _usdm;
        manager = _poolManager;
    }

    function initializePool(OutcomeDetails[] calldata _outcomeDetails) external returns (PoolId[] memory lpPools) {
        Outcome[] memory outcomes = _deployOutcomeTokens(_outcomeDetails);
        PoolId[] memory lpPools = _initializeOutcomePools(outcomes);
        return lpPools;
    }

    function getPoolKeyByPoolId(PoolId _poolId) external view returns (PoolKey memory) {
        return poolKeys[_poolId];
    }

    function initializeMarket(uint24 _fee, bytes memory _eventIpfsHash, OutcomeDetails[] calldata _outcomeDetails)
        external
        override
        returns (PoolId[] memory lpPools, Outcome[] memory outcomes, IOracle oracle)
    {
        Outcome[] memory outcomes = _deployOutcomeTokens(_outcomeDetails);
        PoolId[] memory lpPools = _initializeOutcomePools(outcomes);
        _seedSingleSidedLiquidity(lpPools);

        bytes32 eventId = _initializeEvent(_fee, _eventIpfsHash, outcomes, lpPools);
        IOracle oracle = _deployOracle(_eventIpfsHash);
        _initializeMarket(_fee, eventId, oracle);
        return (lpPools, outcomes, oracle);
    }

    function settle(bytes32 marketId, int16 outcome) public virtual override {
        Market storage market = markets[marketId];

        // Check empty market
        require(market.creator != address(0), "PredictionMarket: Market not found");
        require(market.stage == Stage.STARTED, "PredictionMarket: Market not started");
        require(msg.sender == market.creator, "PredictionMarket: Only market creator can settle");

        // Effects
        Event storage pmmEvent = events[market.eventId];

        pmmEvent.outcomeResolution = outcome;
        pmmEvent.isOutcomeSet = true;

        market.stage = Stage.RESOLVED;
        market.oracle.setOutcome(outcome);

        // Interactions
        int128 losingUsdmAmount;

        // Move funds to the winning pool
        // Needs to be re-thinked (unsafe casting）
        for (int24 i; i < int24(int256(pmmEvent.lpPools.length)); i++) {
            // Skip winning pool
            if (i == outcome) {
                continue;
            }

            // Remove liquidity from losing pools
            Event memory pmmEvent = events[market.eventId];
            PoolId poolId = pmmEvent.lpPools[uint256(int256(i))];
            PoolKey memory poolKey = poolKeys[poolId];

            IPoolManager.ModifyLiquidityParams memory singleSidedLiquidityParams = providedLiquidity[poolId];

            // To remove liquidity, negate the liquidityDelta
            singleSidedLiquidityParams.liquidityDelta = -singleSidedLiquidityParams.liquidityDelta;

            BalanceDelta delta = _modifyLiquidity(poolKey, singleSidedLiquidityParams, ZERO_BYTES, false, false);
            bool isUsdmCcy0 = poolKey.currency0.toId() == usdm.toId();
            losingUsdmAmount += isUsdmCcy0 ? delta.amount0() : delta.amount1();
        }

        // Move USDM to the winning pool
        PoolId winningPoolId = pmmEvent.lpPools[uint16(outcome)];
        PoolKey memory winningPoolKey = poolKeys[winningPoolId];

        // @dev - Calculate tickLower, tickUpper & liquidityDelta to reflect "losingUsdmAmount"
        IPoolManager.ModifyLiquidityParams memory settlementLiquidityPoolParams = IPoolManager.ModifyLiquidityParams({
            tickLower: 0,
            tickUpper: 100,
            liquidityDelta: losingUsdmAmount,
            salt: 0
        });

        // @dev - Add Single Sided Liquidity to the winning pool (just for USDM)

        emit MarketResolved(marketId, outcome);
    }

    function _deployOutcomeTokens(OutcomeDetails[] calldata _outcomeDetails) internal returns (Outcome[] memory) {
        Outcome[] memory outcomes = new Outcome[](_outcomeDetails.length);
        for (uint256 i = 0; i < _outcomeDetails.length; i++) {
            OutcomeToken outcomeToken = new OutcomeToken(_outcomeDetails[i].name);
            outcomeToken.approve(address(manager), type(uint256).max);
            outcomeToken.approve(address(this), type(uint256).max);
            outcomes[i] = Outcome(Currency.wrap(address(outcomeToken)), _outcomeDetails[i]);
        }
        return outcomes;
    }

    function _initializeOutcomePools(Outcome[] memory _outcomes) internal returns (PoolId[] memory) {
        uint256 outcomesLength = _outcomes.length;
        PoolId[] memory lpPools = new PoolId[](outcomesLength);
        // Deploy LP pools for each outcome
        for (uint256 i = 0; i < outcomesLength; i++) {
            {
                Outcome memory outcome = _outcomes[i];
                IERC20 outcomeToken = IERC20(Currency.unwrap(outcome.outcomeToken));
                IERC20 usdmToken = IERC20(Currency.unwrap(usdm));
                (Currency currency0, Currency currency1) = SortTokens.sort(outcomeToken, usdmToken);

                // @dev - address(this) needs to be a Hook
                PoolKey memory poolKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(this)));
                lpPools[i] = poolKey.toId();

                bool isToken0 = currency0.toId() == Currency.wrap(address(outcomeToken)).toId();
                (int24 lowerTick, int24 upperTick) = getTickRange(isToken0);
                int24 initialTick = isToken0 ? lowerTick - TICK_SPACING : upperTick + TICK_SPACING;
                uint160 initialSqrtPricex96 = TickMath.getSqrtPriceAtTick(initialTick);

                manager.initialize(poolKey, initialSqrtPricex96, ZERO_BYTES);
                poolKeys[lpPools[i]] = poolKey;
            }
        }

        return lpPools;
    }

    function _seedSingleSidedLiquidity(PoolId[] memory _lpPools) internal {
        for (uint256 i; i < _lpPools.length; i++) {
            PoolId poolId = _lpPools[i];
            PoolKey memory poolKey = poolKeys[poolId];

            require(
                poolKey.currency0.toId() != Currency.wrap(address(0)).toId()
                    && poolKey.currency1.toId() != Currency.wrap(address(0)).toId(),
                "PredictionMarket: Pool not found"
            );

            //   If not USDM, then it is the outcome token
            bool isOutcomeToken0 = poolKey.currency0.toId() != usdm.toId();
            (int24 tickLower, int24 tickUpper) = getTickRange(isOutcomeToken0);

            IPoolManager.ModifyLiquidityParams memory singleSidedLiquidityParams = IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 100e18,
                salt: 0 // Introduce salt here to prevent duplicate liquidity provided
            });
            providedLiquidity[poolId] = singleSidedLiquidityParams;
            _modifyLiquidity(poolKey, singleSidedLiquidityParams, ZERO_BYTES, false, false);
        }
    }

    function _modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData,
        bool settleUsingBurn,
        bool takeClaims
    ) public payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, settleUsingBurn, takeClaims))),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function _initializeEvent(
        uint24 _fee,
        bytes memory _eventIpfsHash,
        Outcome[] memory _outcomes,
        PoolId[] memory _lpPools
    ) internal returns (bytes32 eventId) {
        Event memory pmmEvent = Event({
            collateralToken: usdm,
            ipfsHash: _eventIpfsHash,
            isOutcomeSet: false,
            outcomeResolution: -1,
            outcomes: new Outcome[](0),
            lpPools: new PoolId[](0)
        });

        eventId = keccak256(abi.encode(usdm, _eventIpfsHash, false, -1, _outcomes, _lpPools));

        for (uint256 i = 0; i < _outcomes.length; i++) {
            events[eventId].outcomes.push(_outcomes[i]);
        }

        for (uint256 i = 0; i < _lpPools.length; i++) {
            events[eventId].lpPools.push(_lpPools[i]);
        }

        emit EventCreated(eventId);

        return eventId;
    }

    function _initializeMarket(uint24 _fee, bytes32 _eventId, IOracle _oracle) internal returns (bytes32 marketId) {
        Market memory market = Market({
            stage: Stage.CREATED,
            creator: msg.sender,
            createdAtBlock: block.number,
            eventId: _eventId,
            oracle: _oracle,
            fee: _fee
        });

        marketId = keccak256(abi.encode(market));
        markets[marketId] = market;
        userMarkets[msg.sender].push(marketId);

        emit MarketCreated(marketId, msg.sender);
    }

    function _deployOracle(bytes memory ipfsHash) internal returns (IOracle) {
        return new CentralisedOracle(ipfsHash, address(this));
    }

    // Liquidity range provided from $0.01 - $10
    function getTickRange(bool isToken0) private pure returns (int24 lowerTick, int24 upperTick) {
        if (isToken0) {
            return (-46050, 23030); // TOKEN to USDM
        } else {
            return (-23030, 46050); // USDM to TOKEN
        }
    }

    function _fetchBalances(Currency currency, address user, address deltaHolder)
        internal
        view
        returns (uint256 userBalance, uint256 poolBalance, int256 delta)
    {
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(manager));
        delta = manager.currencyDelta(deltaHolder, currency);
    }
}
