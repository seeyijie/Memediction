// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IOracle} from "./interface/IOracle.sol";
import {PredictionMarket} from "./PredictionMarket.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {NoDelegateCall} from "v4-core/src/NoDelegateCall.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

    constructor(Currency _usdm, IPoolManager _poolManager)
        PredictionMarket(_usdm, _poolManager)
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
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // Only allow hook to remove liquidity
            afterRemoveLiquidity: false,
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
        // @dev - Check if outcome has been set
        Event memory pmEvent = poolIdToEvent[key.toId()];
        if (!pmEvent.isOutcomeSet) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // How much to claim ???

        // NO-OP
        int128 amountToSettle; // Implement based on claim mechanism
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-swapParams.amountSpecified), amountToSettle);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        Event memory pmEvent = poolIdToEvent[poolKey.toId()];

        if (pmEvent.isOutcomeSet) {
            return (this.afterSwap.selector, 0);
        }

        bool isUsdmCcy0 = poolKey.currency0.toId() == usdm.toId();
        bool isUserBuyingOutcomeToken = (swapParams.zeroForOne && isUsdmCcy0) || (!swapParams.zeroForOne && !isUsdmCcy0);

        int256 outcomeTokenAmount = isUsdmCcy0 ? delta.amount1() : delta.amount0();

        // If user is buying outcome token (+)
        if (isUserBuyingOutcomeToken) {
            outcomeTokenCirculatingSupply[poolKey.toId()] += uint256(outcomeTokenAmount);
        } else {
            // If user is selling outcome token (-)
            outcomeTokenCirculatingSupply[poolKey.toId()] -= uint256(-outcomeTokenAmount);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * Only allows the hook to add liquidity here
     */
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyHook
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
    ) external override onlyHook noDelegateCall returns (bytes4) {
        return (this.beforeRemoveLiquidity.selector);
    }

    modifier onlyHook() {
        require(msg.sender == address(poolManager), "PredictionMarketHook: only hook can call this function");
        _;
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        uint128 liquidityBefore = poolManager.getPosition(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        ).liquidity;

        (BalanceDelta delta,) = poolManager.modifyLiquidity(data.key, data.params, data.hookData);

        uint128 liquidityAfter = poolManager.getPosition(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        ).liquidity;

        (,, int256 delta0) = _fetchBalances(data.key.currency0, address(this), address(this));
        (,, int256 delta1) = _fetchBalances(data.key.currency1, address(this), address(this));

        require(
            int128(liquidityBefore) + data.params.liquidityDelta == int128(liquidityAfter), "liquidity change incorrect"
        );

        if (data.params.liquidityDelta < 0) {
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (data.params.liquidityDelta > 0) {
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }

        if (delta0 < 0) data.key.currency0.settle(poolManager, address(this), uint256(-delta0), data.settleUsingBurn);
        if (delta1 < 0) data.key.currency1.settle(poolManager, address(this), uint256(-delta1), data.settleUsingBurn);
        if (delta0 > 0) data.key.currency0.take(poolManager, address(this), uint256(delta0), data.takeClaims);
        if (delta1 > 0) data.key.currency1.take(poolManager, address(this), uint256(delta1), data.takeClaims);

        return abi.encode(delta);
    }

    function _fetchBalances(Currency currency, address user, address deltaHolder)
        internal
        view
        returns (uint256 userBalance, uint256 poolBalance, int256 delta)
    {
        userBalance = currency.balanceOf(user);
        poolBalance = currency.balanceOf(address(poolManager));
        delta = poolManager.currencyDelta(deltaHolder, currency);
    }

    function getPriceInUsdm(PoolId poolId) public view returns (uint256) {
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        uint256 sqrtPriceX96Uint = uint256(sqrtPriceX96);
        PoolKey memory poolKey = poolKeys[poolId];
        Currency curr0 = poolKey.currency0;
        Currency curr1 = poolKey.currency1;
        uint8 curr0Decimals = ERC20(Currency.unwrap(curr0)).decimals();
        uint8 curr1Decimals = ERC20(Currency.unwrap(curr1)).decimals();

        bool isCurr0Usdm = curr0.toId() == usdm.toId();
        bool isCurr1Usdm = curr1.toId() == usdm.toId();

        require(isCurr0Usdm || isCurr1Usdm, "Neither currency is USDM");

        uint256 price;

        if (isCurr0Usdm) {
            // curr0 is USDM, calculate price of curr1 in terms of USDM (inverse price)
            uint256 numerator = (1 << 192) * 1e18;
            uint256 denominator = sqrtPriceX96Uint * sqrtPriceX96Uint;
            uint256 decimalsDifference;

            if (curr1Decimals >= curr0Decimals) {
                decimalsDifference = curr1Decimals - curr0Decimals;
                numerator *= 10 ** decimalsDifference;
            } else {
                decimalsDifference = curr0Decimals - curr1Decimals;
                denominator *= 10 ** decimalsDifference;
            }

            price = numerator / denominator;
        } else if (isCurr1Usdm) {
            // curr1 is USDM, calculate price of curr0 in terms of USDM
            uint256 numerator = sqrtPriceX96Uint * sqrtPriceX96Uint * 1e18;
            uint256 denominator = 1 << 192;
            uint256 decimalsDifference;

            if (curr0Decimals >= curr1Decimals) {
                decimalsDifference = curr0Decimals - curr1Decimals;
                numerator *= 10 ** decimalsDifference;
            } else {
                decimalsDifference = curr1Decimals - curr0Decimals;
                denominator *= 10 ** decimalsDifference;
            }

            price = numerator / denominator;
        }

        return price;
    }


}
