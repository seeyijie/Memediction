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

contract PredictionMarket is IPredictionMarket {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Contract events to be emitted

    //// END /////


    // @dev - Revisit this value to make it modifiable
    // Smaller ticks have more precision, but cost more gas (vice-versa)
    int24 public TICK_SPACING = 10;
    uint24 public FEE = 0; // 0% fee

    Currency immutable usdm; // Should be over-collateralized stable coin (implementation not important here)
    PoolManager immutable poolManager;

    address public predictionMarketHook; // Hook contract for prediction markets

    // Store marketId to Market mapping
    mapping(bytes32 => Market) public markets;

    // Store eventId to Event mapping
    mapping(bytes32 => Event) public events;

    // Store list of all created markets for an address
    mapping(address => bytes32[]) public userMarkets;

    constructor(Currency _usdm, PoolManager _poolManager) {
        usdm = _usdm;
        poolManager = _poolManager;

        predictionMarketHook = address(this); // @dev - Depends if we want to separate this out
    }

    function initializeMarket(uint24 _fee, string calldata _question, OutcomeDetails[] calldata _outcomeDetails) virtual external {
        // Deploy ERC20 contracts, depending on each outcome
        Outcome[] memory outcomes = _deployOutcomeTokens(_outcomeDetails);

        // Initialize pools for each outcome
        PoolId[] memory lpPools = _initializeOutcomePools(outcomes);

        bytes32 pmmEventId = _initializeEvent(_fee, _question, outcomes, lpPools);

        // Deploy oracle here, with "creator" as the admin
        // deployOracle

        // Initialize Market here
        Market memory market = _initializeMarket(_fee, pmmEventId);
    }

    /**
     * @dev - Replace this with ERC20 minimal proxy pattern to save gas
     * https://blog.openzeppelin.com/deep-dive-into-the-minimal-proxy-contract
     */
    function _deployOutcomeTokens(OutcomeDetails[] calldata _outcomeDetails) internal returns (Outcome[] memory) {
        Outcome[] memory outcomes = new Outcome[](_outcomeDetails.length);
        for (uint i = 0; i < _outcomeDetails.length; i++) {
            OutcomeToken outcomeToken = new OutcomeToken(_outcomeDetails[i].name);
            outcomes[i] = Outcome(Currency.wrap(address(outcomeToken)), _outcomeDetails[i]);
        }
        return outcomes;
    }

    /**
     * @dev - Should this be inside a hook? Or its own separate contract?
     * This is gas intensive, need to make sure it's optimized
     */
    function _initializeOutcomePools(Outcome[] memory _outcomes) internal returns (PoolId[] memory) {
        uint outcomesLength = _outcomes.length;
        PoolId[] memory lpPools = new PoolId[](outcomesLength);

        for (uint i = 0; i < outcomesLength; i++) {
            Outcome memory outcome = _outcomes[i];

            // Extract currencies for the current outcome
            IERC20 outcomeToken = IERC20(Currency.unwrap(outcome.outcomeToken));
            IERC20 usdmToken = IERC20(Currency.unwrap(usdm));
            (Currency currency0, Currency currency1) = SortTokens.sort(outcomeToken, usdmToken);

            // Create a pool key with the defined parameters
            PoolKey memory poolKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(predictionMarketHook));
            lpPools[i] = poolKey.toId();

            // Initialize the tick range
            bool isToken0 = currency0.toId() == Currency.wrap(address(outcomeToken)).toId();
            (int24 lowerTick, int24 upperTick) = getTickRange(isToken0);

            int24 initialTick = isToken0 ? lowerTick - TICK_SPACING : upperTick + TICK_SPACING;
            uint160 initialSqrtPricex96 = TickMath.getSqrtPriceAtTick(initialTick);

            // Initialize the pool with the calculated initial price
            poolManager.initialize(poolKey, initialSqrtPricex96, "");
        }

        return lpPools;
    }

    function _initializeEvent(uint24 _fee, string calldata _question, Outcome[] memory _outcomes, PoolId[] memory _lpPools) internal returns (bytes32 eventId) {
        // Create a new event
        Event memory pmmEvent = Event({
            collateralToken: usdm,
            question: _question,
            isOutcomeSet: false,
            outcomeResolution: -1,
            outcomes: _outcomes, // We'll copy this manually
            lpPools: _lpPools
        });

        // Store the event in the contract
        bytes32 eventId = keccak256(abi.encode(pmmEvent));
        events[eventId].collateralToken = pmmEvent.collateralToken;
        events[eventId].question = pmmEvent.question;
        events[eventId].isOutcomeSet = pmmEvent.isOutcomeSet;
        events[eventId].outcomeResolution = pmmEvent.outcomeResolution;

        // Manually copy the outcomes array
        for (uint i = 0; i < _outcomes.length; i++) {
            events[eventId].outcomes.push(_outcomes[i]);
        }

        // Copy the lpPools array manually if necessary
        for (uint i = 0; i < _lpPools.length; i++) {
            events[eventId].lpPools.push(_lpPools[i]);
        }

        // Emit event created

        return eventId;

    }

    function _initializeMarket(uint24 _fee, bytes32 _eventId) internal returns (Market memory) {
        // Create a new market
        Market memory market = Market({
            stage: Stage.CREATED,
            creator: msg.sender,
            createdAtBlock: block.number,
            eventId: _eventId,
            oracle: IOracle(address(0)),
            fee: _fee
        });

        // Store the market in the contract
        bytes32 marketId = keccak256(abi.encode(market));
        markets[marketId] = market;

        // Store the marketId in the user's list of markets
        userMarkets[msg.sender].push(marketId);

        // Emit market created

        return market;
    }


    // @dev - Abstract this out to a library
    // @dev - Make the numbers here modifiable by an admin
    // Provide from TOKEN = $0.01 - $10 price range
    // Price = 1.0001^(tick), rounded to nearest tick
    function getTickRange(bool isToken0) private pure returns (int24 lowerTick, int24 upperTick) {
        if (isToken0) {
            // lowerTick = −46,054, upperTick = 23,027
            return (-46050, 23030); // TOKEN to USDM
        } else {
            // lowerTick = −23,030, upperTick = 46,054
            return (-23030, 46050); // USDM to TOKEN
        }
    }


    function startEvent(uint _marketId) virtual external {}
}