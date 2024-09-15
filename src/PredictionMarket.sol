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

/**
 * @title PredictionMarket
 * @notice Abstract contract for creating and managing prediction markets.
 */
abstract contract PredictionMarket is IPredictionMarket {
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

    // Mappings
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Event) public events;
    mapping(address => bytes32[]) public userMarkets;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(PoolId => Event) public poolIdToEvent;

    mapping(PoolId => uint256 supply) public outcomeTokenCirculatingSupply; // Circulating supply of outcome tokens
    mapping(PoolId => IPoolManager.ModifyLiquidityParams) public providedLiquidity;

    // Struct used in manager.unlock()
    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
    }

    /**
     * @notice Constructor
     * @param _usdm The USDM currency used as collateral
     * @param _poolManager The Uniswap V4 PoolManager contract
     */
    constructor(Currency _usdm, IPoolManager _poolManager) {
        usdm = _usdm;
        manager = _poolManager;
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
        outcomes = _deployOutcomeTokens(_outcomeDetails);
        lpPools = _initializeOutcomePools(outcomes);
        _seedSingleSidedLiquidity(lpPools);

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
        require(market.creator != address(0), "Market not found");
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
        require(outcome >= 0, "Invalid outcome");
        require(market.creator != address(0), "Market not found");
        require(market.stage == Stage.STARTED, "Market not started");
        require(msg.sender == market.creator, "Only market creator can settle");

        // Update event outcome
        Event storage pmmEvent = events[market.eventId];
        pmmEvent.outcomeResolution = outcome;
        pmmEvent.isOutcomeSet = true;

        // Update market stage and set outcome in oracle
        market.stage = Stage.RESOLVED;
        market.oracle.setOutcome(outcome);

        // Interactions
        uint256 losingUsdmAmount;

        // Remove liquidity from losing pools and collect USDM amounts
        for (uint256 i = 0; i < pmmEvent.lpPools.length; i++) {
            if (int16(int256(i)) == outcome) {
                continue; // Skip winning pool
            }

            // Remove liquidity from losing pools
            PoolId poolId = pmmEvent.lpPools[i];
            PoolKey memory poolKey = poolKeys[poolId];

            IPoolManager.ModifyLiquidityParams memory liquidityParams = providedLiquidity[poolId];

            // Negate the liquidityDelta to remove liquidity
            liquidityParams.liquidityDelta = -liquidityParams.liquidityDelta;

            // Remove liquidity and get the balance delta
            BalanceDelta delta = _modifyLiquidity(poolKey, liquidityParams, ZERO_BYTES, false, false);

            delete providedLiquidity[poolId];

            bool isUsdmCurrency0 = poolKey.currency0.toId() == usdm.toId();
            int256 usdmDelta = isUsdmCurrency0 ? delta.amount0() : delta.amount1();

            // Accumulate the amount of USDM obtained
            if (usdmDelta > 0) {
                losingUsdmAmount += uint256(usdmDelta);
            } else {
                losingUsdmAmount += uint256(-usdmDelta); // Convert negative amount to positive
            }
        }

        // Move USDM to the winning pool
        PoolId winningPoolId = pmmEvent.lpPools[uint256(uint16(outcome))];
        PoolKey memory winningPoolKey = poolKeys[winningPoolId];

        // Get current tick for the winning pool
        (, int24 currentTick,,) = manager.getSlot0(winningPoolId);
        bool isUsdmCurrency0 = winningPoolKey.currency0.toId() == usdm.toId();

        (int24 tickLower, int24 tickUpper) = getTickRange(isUsdmCurrency0);

        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 liquidityDelta;

        if (isUsdmCurrency0) {
            // For currency1 (USDM) amount
            liquidityDelta = (losingUsdmAmount * FixedPoint96.Q96) / (sqrtPriceUpper - sqrtPriceLower);
        } else {
            // For currency0 (USDM) amount
            uint256 inverseSqrtPriceLower = getInverseSqrt(sqrtPriceLower);
            uint256 inverseSqrtPriceUpper = getInverseSqrt(sqrtPriceUpper);
            liquidityDelta = (losingUsdmAmount * FixedPoint96.Q96) / (inverseSqrtPriceLower - inverseSqrtPriceUpper);
        }

        // Provide liquidity to the winning pool
        IPoolManager.ModifyLiquidityParams memory settlementLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: SafeCast.toInt256(liquidityDelta),
            salt: 0 // Consider introducing a salt here to prevent duplicate liquidity provision
        });

        // Add liquidity to the winning pool
        _modifyLiquidity(winningPoolKey, settlementLiquidityParams, ZERO_BYTES, false, false);

        emit MarketResolved(marketId, outcome);
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

        // Deploy LP pools for each outcome
        for (uint256 i = 0; i < outcomesLength; i++) {
            Outcome memory outcome = outcomes[i];
            IERC20 outcomeToken = IERC20(Currency.unwrap(outcome.outcomeToken));
            IERC20 usdmToken = IERC20(Currency.unwrap(usdm));

            (Currency currency0, Currency currency1) = SortTokens.sort(outcomeToken, usdmToken);

            // Ensure this contract implements IHooks
            PoolKey memory poolKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(this)));
            lpPools[i] = poolKey.toId();

            bool isToken0 = currency0.toId() == Currency.wrap(address(outcomeToken)).toId();
            (int24 lowerTick, int24 upperTick) = getTickRange(isToken0);
            int24 initialTick = isToken0 ? lowerTick - TICK_SPACING : upperTick + TICK_SPACING;
            uint160 initialSqrtPricex96 = TickMath.getSqrtPriceAtTick(initialTick);

            manager.initialize(poolKey, initialSqrtPricex96, ZERO_BYTES);
            poolKeys[lpPools[i]] = poolKey;
        }

        return lpPools;
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
            (int24 tickLower, int24 tickUpper) = getTickRange(isOutcomeToken0);

            IPoolManager.ModifyLiquidityParams memory liquidityParams = IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 100e18,
                salt: 0 // Optionally introduce salt to prevent duplicate liquidity provision
            });
            providedLiquidity[poolId] = liquidityParams;
            _modifyLiquidity(poolKey, liquidityParams, ZERO_BYTES, false, false);
        }
    }

    /**
     * @notice Modifies liquidity in a pool
     * @param key The pool key
     * @param params The liquidity modification parameters
     * @param hookData Additional hook data
     * @param settleUsingBurn Whether to settle using burn
     * @param takeClaims Whether to take claims
     * @return delta The balance delta resulting from the liquidity modification
     */
    function _modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData,
        bool settleUsingBurn,
        bool takeClaims
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, settleUsingBurn, takeClaims))),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
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
    function getTickRange(bool isToken0) private pure returns (int24 lowerTick, int24 upperTick) {
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
}