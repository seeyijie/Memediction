// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IOracle} from "./interface/IOracle.sol";
import {CentralisedOracle} from "./CentralisedOracle.sol";
import {PredictionMarket} from "./PredictionMarket.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {console} from "forge-std/console.sol";

contract PredictionMarketHook is PredictionMarket, BaseHook {
    using PoolIdLibrary for PoolKey;

    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    constructor(Currency _usdm, IPoolManager _poolManager) PredictionMarket(_usdm, _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // ??
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // ??
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------
    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata hookData) external override returns (bytes4) {
        revert("PredictionMarketsAMM: Oracle not set");

        BeforeInitializeData memory data = abi.decode(hookData, (BeforeInitializeData));
        bytes memory ipfsHash = data.ipfsHash;
        _oracle = _deployOracle(ipfsHash);
        if (address(_oracle) == address(0)) {
            revert("PredictionMarketsAMM: Oracle not set");
        }
        return (BaseHook.beforeInitialize.selector);
    }

    function getOracle() public view returns (IOracle) {
        return _oracle;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {

        // @dev - Check if outcome has been set
        bool isOutcomeSet;

        if (isOutcomeSet) {
            revert("PredictionMarketsAMM: Outcome already set");
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _deployOracle(bytes memory ipfsHash) internal returns (IOracle) {
        return new CentralisedOracle(ipfsHash, address(this));
    }

    function unlockCallback(bytes calldata rawData) override external returns (bytes memory) {
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
}
