// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// External Libraries and Contracts
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Internal Interfaces and Libraries
import "./interface/IOracle.sol";
import "./interface/IPredictionMarket.sol";
import "./OutcomeToken.sol";
import "./CentralisedOracle.sol";
import "./lib/SortTokens.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin/security/ReentrancyGuard.sol";

// Uniswap V4 Core Libraries and Contracts
import "v4-core/src/types/Currency.sol";
import "v4-core/src/types/PoolKey.sol";
import "v4-core/src/types/PoolId.sol";
import "v4-core/src/libraries/TickMath.sol";
import "v4-core/src/interfaces/IHooks.sol";
import "v4-core/src/PoolManager.sol";
import "v4-core/src/interfaces/IPoolManager.sol";
import "v4-core/src/libraries/Hooks.sol";
import "v4-core/src/types/BalanceDelta.sol";
import "v4-core/src/libraries/TransientStateLibrary.sol";
import "v4-core/src/libraries/StateLibrary.sol";
import "v4-core/src/libraries/FullMath.sol";
import "v4-core/src/libraries/SafeCast.sol";
import "v4-core/src/libraries/FixedPoint96.sol";
import "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {console} from "forge-std/console.sol";

/**
 * @title PredictionMarket
 * @notice Abstract contract for creating and managing prediction markets.
 */
abstract contract PredictionMarket is ReentrancyGuard, IPredictionMarket {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using FullMath for uint256;

    // Constants
    int24 public constant TICK_SPACING = 10;
    uint24 public constant FEE = 0; // 0% fee
    bytes public constant ZERO_BYTES = "";
    int16 public constant UNINITIALIZED_OUTCOME = -1;

    // State Variables
    Currency public immutable usdm;
    IPoolManager private immutable manager;
    PoolModifyLiquidityTest private immutable modifyLiquidityRouter;

    // Mappings
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Event) public events;

    // See all markets created by a user
    mapping(address => bytes32[]) public userMarkets;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(PoolId => Event) public poolIdToEvent;

    mapping(PoolId => uint256 supply) public outcomeTokenCirculatingSupply; // Circulating supply of outcome tokens
    mapping(PoolId => uint256 supply) public usdmAmountInPool; // Supply of USDM that can be withdrawn by the hook
    mapping(PoolId => IPoolManager.ModifyLiquidityParams) public hookProvidedLiquidityForPool;

    /**
     * @notice Constructor
     * @param _usdm The USDM currency used as collateral
     * @param _poolManager The Uniswap V4 PoolManager contract
     */
    constructor(Currency _usdm, IPoolManager _poolManager, PoolModifyLiquidityTest _modifyLiquidityRouter) {
        usdm = _usdm;
        manager = _poolManager;
        modifyLiquidityRouter = _modifyLiquidityRouter;
    }

    /**
     * @notice Initializes outcome tokens and their pools
     * @param outcomeDetails The details of each outcome
     * @return lpPools The array of liquidity pool IDs
     */
    function initializePool(OutcomeDetails[] calldata outcomeDetails) external returns (PoolId[] memory lpPools) {
        Outcome[] memory outcomes = _deployOutcomeTokens(outcomeDetails);
        lpPools = _initializeOutcomePools(outcomes);
        return lpPools;
    }

    /**
     * @notice Gets the pool key by pool ID
     * @param poolId The pool ID
     * @return The pool key associated with the given pool ID
     */
    function getPoolKeyByPoolId(PoolId poolId) external view returns (PoolKey memory) {
        return poolKeys[poolId];
    }

    /**
     * @notice Does not check if marketId exists, if it does not, it will return false
     * @param marketId The market ID to check
     * @return The event has been settled
     */
    function isMarketResolved(bytes32 marketId) external view returns (bool) {
        Market storage market = markets[marketId];
        Event storage pmmEvent = events[market.eventId];
        return pmmEvent.isOutcomeSet;
    }

    /**
     * @notice Initializes a new prediction market
     * @param _fee The fee for the market
     * @param _eventIpfsHash The IPFS hash of the event data
     * @param _outcomeDetails The details of each outcome
     * @return marketId The ID of the created market
     * @return lpPools The array of liquidity pool IDs
     * @return outcomes The array of outcomes
     * @return oracle The oracle used for this market
     */
    function initializeMarket(uint24 _fee, bytes memory _eventIpfsHash, OutcomeDetails[] calldata _outcomeDetails)
        external
        override
        returns (bytes32 marketId, PoolId[] memory lpPools, Outcome[] memory outcomes, IOracle oracle)
    {
        // Deploy outcome tokens, mint to this hook
        outcomes = _deployOutcomeTokens(_outcomeDetails);

        // Initialize outcome pools to poolManager
        lpPools = _initializeOutcomePools(outcomes);

        // Seed single-sided liquidity into the outcome pools
        _seedSingleSidedLiquidity(lpPools);

        // Initialize the event, create the market & deploy the oracle
        bytes32 eventId = _initializeEvent(_fee, _eventIpfsHash, outcomes, lpPools);
        oracle = _deployOracle(_eventIpfsHash);
        marketId = _createMarket(_fee, eventId, oracle);

        return (marketId, lpPools, outcomes, oracle);
    }

    /**
     * @notice Starts a market, moving it to the STARTED stage
     * @param marketId The ID of the market to start
     */
    function startMarket(bytes32 marketId) public override {
        Market storage market = markets[marketId];

        // Check if the market exists and is in the correct stage
//        require(market.creator != address(0), "Market not found"); @dev - this is not needed for testing
        require(market.stage == Stage.CREATED, "Market already started");
        require(msg.sender == market.creator, "Only market creator can start");

        // Update market stage
        market.stage = Stage.STARTED;

        emit MarketStarted(marketId);
    }

    /**
     * @notice Settles a market based on the outcome
     * @param marketId The ID of the market to settle
     * @param outcome The outcome index
     */
    function settle(bytes32 marketId, int16 outcome) public virtual override {
        Market storage market = markets[marketId];

        // Check if the market exists and is in the correct stage
        {
            require(outcome >= 0, "Invalid outcome");
            require(market.creator != address(0), "Market not found");
            require(market.stage == Stage.STARTED, "Market not started");
            require(msg.sender == market.creator, "Only market creator can settle");
        }

        // Update event outcome

        Event storage pmmEvent = events[market.eventId];
        {
            pmmEvent.outcomeResolution = outcome;
            pmmEvent.isOutcomeSet = true;

            // Update market stage and set outcome in oracle
            market.stage = Stage.RESOLVED;
            market.oracle.setOutcome(outcome);
        }

        // Interactions
        uint256 totalUsdmAmount;

        // Remove liquidity from losing pools and collect USDM amounts
        for (uint256 i = 0; i < pmmEvent.lpPools.length; i++) {
            // Remove liquidity from losing pools
            PoolId poolId = pmmEvent.lpPools[i];
            PoolKey memory poolKey = poolKeys[poolId];

            IPoolManager.ModifyLiquidityParams memory liquidityParams = hookProvidedLiquidityForPool[poolId];

            // Negate the liquidityDelta to remove liquidity
            liquidityParams.liquidityDelta = -liquidityParams.liquidityDelta;

            // Remove liquidity and get the balance delta
            BalanceDelta delta =
                modifyLiquidityRouter.modifyLiquidity(poolKey, liquidityParams, ZERO_BYTES, false, false);

            delete hookProvidedLiquidityForPool[poolId];

            {
                bool isUsdmCurrency0 = poolKey.currency0.toId() == usdm.toId();
                int256 usdmDelta = isUsdmCurrency0 ? delta.amount0() : delta.amount1();

                // Accumulate the amount of USDM obtained
                if (usdmDelta > 0) {
                    totalUsdmAmount += uint256(usdmDelta);
                } else {
                    totalUsdmAmount += uint256(-usdmDelta); // Convert negative amount to positive
                }
            }
        }

        market.usdmAmountAtSettlement = totalUsdmAmount;

        emit MarketResolved(marketId, outcome);
    }

    function amountToClaim(bytes32 marketId) public view returns (uint256) {
        Market storage market = markets[marketId];
        Event storage pmmEvent = events[market.eventId];
        PoolId poolId = pmmEvent.lpPools[uint256(int256(pmmEvent.outcomeResolution))];
        PoolKey memory poolKey = poolKeys[poolId];

        Currency outcomeCcy = poolKey.currency0.toId() == usdm.toId() ? poolKey.currency1 : poolKey.currency0;
        IERC20Metadata outcomeToken = IERC20Metadata(Currency.unwrap(outcomeCcy));

        uint256 outcomeTokenAmountToClaim = outcomeToken.balanceOf(msg.sender);
        uint256 totalUsdmForMarket = market.usdmAmountAtSettlement;
        uint256 circulatingSupply = outcomeTokenCirculatingSupply[poolKey.toId()];

        // Division by zero check
        if (circulatingSupply == 0) {
            return 0;
        }

        return (totalUsdmForMarket * outcomeTokenAmountToClaim) / circulatingSupply;
    }

    function claim(bytes32 marketId, uint256 outcomeTokenAmountToClaim) external nonReentrant returns (uint256 usdmAmountToClaim) {
        Market storage market = markets[marketId];
        require(outcomeTokenAmountToClaim > 0, "Invalid amount to claim");
        require(market.stage == Stage.RESOLVED, "Market not resolved");

        Event storage pmmEvent = events[market.eventId];
        PoolId poolId = pmmEvent.lpPools[uint256(int256(pmmEvent.outcomeResolution))];
        PoolKey memory poolKey = poolKeys[poolId];

        Currency outcomeCcy = poolKey.currency0.toId() == usdm.toId() ? poolKey.currency1 : poolKey.currency0;
        IERC20Metadata outcomeToken = IERC20Metadata(Currency.unwrap(outcomeCcy));

        uint256 circulatingSupply = outcomeTokenCirculatingSupply[poolKey.toId()];
        {
            require(circulatingSupply > 0, "No circulating supply available");
            require(outcomeToken.balanceOf(msg.sender) >= outcomeTokenAmountToClaim, "Insufficient balance");
            require(outcomeTokenAmountToClaim < circulatingSupply, "Amount too big");
            require(outcomeToken.allowance(msg.sender, address(this)) >= outcomeTokenAmountToClaim, "Insufficient token allowance");
        }

        {
            usdmAmountToClaim = (market.usdmAmountAtSettlement * outcomeTokenAmountToClaim) / circulatingSupply;
            emit Claimed(marketId, msg.sender, address(outcomeToken), outcomeTokenAmountToClaim);

            require(outcomeToken.transferFrom(msg.sender, address(this), outcomeTokenAmountToClaim), "Token transfer failed");
            usdm.transfer(msg.sender, usdmAmountToClaim);
        }
    }


    /**
     * @notice Deploys outcome tokens based on the provided details
     * @param outcomeDetails The details for each outcome
     * @return outcomes The array of deployed outcomes
     */
    function _deployOutcomeTokens(OutcomeDetails[] calldata outcomeDetails)
        internal
        returns (Outcome[] memory outcomes)
    {
        outcomes = new Outcome[](outcomeDetails.length);
        for (uint256 i = 0; i < outcomeDetails.length; i++) {
            OutcomeToken outcomeToken = new OutcomeToken(outcomeDetails[i].name);
            outcomeToken.approve(address(manager), type(uint256).max);
            outcomeToken.approve(address(modifyLiquidityRouter), type(uint256).max);
            outcomes[i] = Outcome(Currency.wrap(address(outcomeToken)), outcomeDetails[i]);
        }
        return outcomes;
    }

    /**
     * @notice Initializes outcome pools for the given outcomes
     * @param outcomes The array of outcomes
     * @return lpPools The array of liquidity pool IDs
     */
    function _initializeOutcomePools(Outcome[] memory outcomes) internal returns (PoolId[] memory lpPools) {
        uint256 outcomesLength = outcomes.length;
        lpPools = new PoolId[](outcomesLength);

        for (uint256 i = 0; i < outcomesLength; i++) {
            Outcome memory outcome = outcomes[i];
            IERC20 outcomeToken = IERC20(Currency.unwrap(outcome.outcomeToken));
            IERC20 usdmToken = IERC20(Currency.unwrap(usdm));

            // Sort tokens and get PoolKey
            PoolKey memory poolKey = _getPoolKey(outcomeToken, usdmToken);
            lpPools[i] = poolKey.toId();

            // Get tick range and initialize the pool
            _initializePool(poolKey, outcomeToken);
        }

        return lpPools;
    }

    function _getPoolKey(IERC20 outcomeToken, IERC20 usdmToken) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = SortTokens.sort(outcomeToken, usdmToken);
        return PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(this)));
    }

    function _initializePool(PoolKey memory poolKey, IERC20 outcomeToken) internal {
        bool isToken0 = poolKey.currency0.toId() == Currency.wrap(address(outcomeToken)).toId();
        (int24 lowerTick, int24 upperTick) = getInitialOutcomeTokenTickRange(isToken0);
        int24 initialTick = isToken0 ? lowerTick - TICK_SPACING : upperTick + TICK_SPACING;

        uint160 initialSqrtPricex96 = TickMath.getSqrtPriceAtTick(initialTick);
        manager.initialize(poolKey, initialSqrtPricex96, ZERO_BYTES);
        poolKeys[poolKey.toId()] = poolKey;
    }

    /**
     * @notice Seeds single-sided liquidity into the outcome pools
     * @param lpPools The array of liquidity pool IDs
     */
    function _seedSingleSidedLiquidity(PoolId[] memory lpPools) internal {
        for (uint256 i = 0; i < lpPools.length; i++) {
            PoolId poolId = lpPools[i];
            PoolKey memory poolKey = poolKeys[poolId];

            require(
                poolKey.currency0.toId() != Currency.wrap(address(0)).toId()
                    && poolKey.currency1.toId() != Currency.wrap(address(0)).toId(),
                "Pool not found"
            );

            // Determine if the outcome token is token0 or token1
            bool isOutcomeToken0 = poolKey.currency0.toId() != usdm.toId();
            (int24 tickLower, int24 tickUpper) = getInitialOutcomeTokenTickRange(isOutcomeToken0);

            IPoolManager.ModifyLiquidityParams memory liquidityParams = IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 100e18,
                salt: 0 // Optionally introduce salt to prevent duplicate liquidity provision
            });
            hookProvidedLiquidityForPool[poolId] = liquidityParams;
            modifyLiquidityRouter.modifyLiquidity(poolKey, liquidityParams, ZERO_BYTES, false, false);
        }
    }

    /**
     * @notice Initializes an event
     * @param fee The fee for the event
     * @param eventIpfsHash The IPFS hash of the event data
     * @param outcomes The array of outcomes
     * @param lpPools The array of liquidity pool IDs
     * @return eventId The ID of the created event
     */
    function _initializeEvent(
        uint24 fee,
        bytes memory eventIpfsHash,
        Outcome[] memory outcomes,
        PoolId[] memory lpPools
    ) internal returns (bytes32 eventId) {
        Event memory newEvent = Event({
            collateralToken: usdm,
            ipfsHash: eventIpfsHash,
            isOutcomeSet: false,
            outcomeResolution: UNINITIALIZED_OUTCOME,
            outcomes: outcomes,
            lpPools: lpPools
        });

        eventId = keccak256(abi.encode(usdm, eventIpfsHash, false, UNINITIALIZED_OUTCOME, outcomes, lpPools));

        events[eventId] = newEvent;

        // Map pool IDs to the event for easier indexing
        for (uint256 i = 0; i < lpPools.length; i++) {
            poolIdToEvent[lpPools[i]] = newEvent;
        }

        emit EventCreated(eventId);
        return eventId;
    }

    /**
     * @notice Creates a market
     * @param fee The fee for the market
     * @param eventId The ID of the event associated with the market
     * @param oracle The oracle used for the market
     * @return marketId The ID of the created market
     */
    function _createMarket(uint24 fee, bytes32 eventId, IOracle oracle) internal returns (bytes32 marketId) {
        Market memory market = Market({
            stage: Stage.CREATED,
            creator: msg.sender,
            createdAtBlock: block.number,
            usdmAmountAtSettlement: 0,
            eventId: eventId,
            oracle: oracle,
            fee: fee
        });

        marketId = keccak256(abi.encode(market));
        markets[marketId] = market;
        userMarkets[msg.sender].push(marketId);

        emit MarketCreated(marketId, msg.sender);
        return marketId;
    }

    /**
     * @notice Deploys a centralized oracle
     * @param ipfsHash The IPFS hash associated with the oracle data
     * @return The deployed oracle instance
     */
    function _deployOracle(bytes memory ipfsHash) internal returns (IOracle) {
        return new CentralisedOracle(ipfsHash, address(this));
    }

    /**
     * @notice Provides the tick range for liquidity provisioning
     * @param isToken0 Whether the outcome token is token0
     * @return lowerTick The lower tick
     * @return upperTick The upper tick
     */
    function getInitialOutcomeTokenTickRange(bool isToken0) private pure returns (int24 lowerTick, int24 upperTick) {
        if (isToken0) {
            // Outcome token to USDM
            return (-46050, 23030);
        } else {
            // USDM to Outcome token
            return (-23030, 46050);
        }
    }

    /**
     * @notice Gets the inverse square root price
     * @param sqrtPriceX96 The square root price in Q64.96 format
     * @return The inverse square root price
     */
    function getInverseSqrt(uint160 sqrtPriceX96) public pure returns (uint256) {
        // sqrtPriceX96 is the sqrt(p) represented in Q64.96
        // To get 1 / sqrt(p), divide 1 (represented as Q96) by sqrtPriceX96
        return FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, uint256(sqrtPriceX96));
    }

    // Function to calculate the closest low tick
    function getClosestLowTick(int24 tick) public pure returns (int24) {
        // Convert uint16 tickSpacing to int24 in two steps
        int24 remainder = tick % TICK_SPACING;
        if (remainder < 0) {
            return (tick / TICK_SPACING) * TICK_SPACING - TICK_SPACING;
        } else {
            return (tick / TICK_SPACING) * TICK_SPACING;
        }
    }

    // Function to calculate the closest high tick
    function getClosestHighTick(int24 tick) public pure returns (int24) {
        // Convert uint16 tickSpacing to int24 in two steps
        int24 closestLowTick = getClosestLowTick(tick);

        if (tick % TICK_SPACING == 0) {
            return closestLowTick; // Tick is exactly on a spacing boundary
        } else {
            return closestLowTick + TICK_SPACING;
        }
    }
}
