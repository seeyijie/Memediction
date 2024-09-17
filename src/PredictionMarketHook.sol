// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IOracle} from "./interface/IOracle.sol";
import {PredictionMarket} from "./PredictionMarket.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {NoDelegateCall} from "v4-core/src/NoDelegateCall.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

contract PredictionMarketHook is BaseHook, PredictionMarket, NoDelegateCall {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------
    error SwapDisabled(PoolId poolId);
    error EventNotFound(PoolId poolId);
    error MarketNotFound(PoolId poolId);

    constructor(Currency _usdm, IPoolManager _poolManager, PoolModifyLiquidityTest _poolModifyLiquidityTest)
        PredictionMarket(_usdm, _poolManager, _poolModifyLiquidityTest)
        BaseHook(_poolManager)
    {}

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager));
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // Deploy oracles, initialize market, event
            afterInitialize: false,
            beforeAddLiquidity: true, // Only allow hook to add liquidity
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true, // Only allow hook to remove liquidity
            afterRemoveLiquidity: true,
            beforeSwap: true, // Check if outcome has been set
            afterSwap: true, // Calculate supply of outcome tokens in pool
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // Claim function for outcome tokens
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------
    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata) external override returns (bytes4) {
        return (BaseHook.beforeInitialize.selector);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Disable swaps if outcome is set
        bytes32 eventId = poolIdToEventId[key.toId()];
        bytes32 marketId = poolIdToMarketId[key.toId()];

        if (eventId == bytes32(0)) {
            revert EventNotFound(key.toId());
        }

        if (marketId == bytes32(0)) {
            revert MarketNotFound(key.toId());
        }

        Event memory pmEvent = events[eventId];
        Market memory pmMarket = markets[marketId];

        // Only allowed to swap if outcome is not set and market is started
        if (!pmEvent.isOutcomeSet && pmMarket.stage == Stage.STARTED) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Revert if outcome is set OR market is not started
        revert SwapDisabled(key.toId());
    }

    function afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        bytes32 eventId = poolIdToEventId[poolKey.toId()];
        Event memory pmEvent = events[eventId];

        // Should not do accounting anymore if outcome is set
        if (pmEvent.isOutcomeSet) {
            return (this.afterSwap.selector, 0);
        }

        bool isUsdmCcy0 = poolKey.currency0.toId() == usdm.toId();
        bool isUserBuyingOutcomeToken = (swapParams.zeroForOne && isUsdmCcy0) || (!swapParams.zeroForOne && !isUsdmCcy0);

        int256 outcomeTokenAmount = isUsdmCcy0 ? delta.amount1() : delta.amount0();
        int256 usdmTokenAmountReceived = isUsdmCcy0 ? delta.amount0() : delta.amount1();

        // If user is buying outcome token (+)
        if (isUserBuyingOutcomeToken) {
            outcomeTokenCirculatingSupply[poolKey.toId()] += uint256(outcomeTokenAmount);
            usdmAmountInPool[poolKey.toId()] += uint256(-usdmTokenAmountReceived);
        } else {
            // If user is selling outcome token (-)
            outcomeTokenCirculatingSupply[poolKey.toId()] -= uint256(-outcomeTokenAmount);
            usdmAmountInPool[poolKey.toId()] -= uint256(usdmTokenAmountReceived);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * Only allows the hook to add liquidity here
     */
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        noDelegateCall
        returns (bytes4)
    {
        return (this.beforeAddLiquidity.selector);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager noDelegateCall returns (bytes4) {
        return (this.beforeRemoveLiquidity.selector);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager noDelegateCall returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager noDelegateCall returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
