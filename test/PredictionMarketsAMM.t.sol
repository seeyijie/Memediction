// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PredictionMarketsAMM} from "../src/PredictionMarketsAMM.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract PredictionMarketsAMMTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    PredictionMarketsAMM hook;
    PoolId poolId;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        deployCodeTo("PredictionMarketsAMM.sol:PredictionMarketsAMM", abi.encode(manager), flags);
        hook = PredictionMarketsAMM(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        console2.log("set up");
        console2.log(hook.owner());
        console2.log(address(this));
        // Provide full-range liquidity to the pool
//        modifyLiquidityRouter.modifyLiquidity(
//            key,
//            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10_000 ether, 0),
//            ZERO_BYTES
//        );
    }

    function testLiquidityHooks() public {
        // positions were created in setup()
//        assertEq(hook.beforeAddLiquidityCount(poolId), 1);
//        assertEq(hook.beforeRemoveLiquidityCount(poolId), 0);

        console2.log("test liquidity hooks");
        address addr = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;
//        vm.startPrank(addr);
        console2.log("deployers address");
        console2.log(address(hook));
        console2.log(hook.owner());
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10_000 ether, 0),
            ZERO_BYTES
        );

//        assertEq(hook.beforeAddLiquidityCount(poolId), 1);
//        assertEq(hook.beforeRemoveLiquidityCount(poolId), 1);
    }
}
