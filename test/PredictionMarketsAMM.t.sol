// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PredictionMarketsAMM} from "../src/PredictionMarketsAMM.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SetUpLibrary} from "./utils/SetUpLibrary.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract PredictionMarketsAMMTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    PredictionMarketsAMM hook;
    PoolId poolId;

    // LP1
    Currency[2] lp1;
    // LP2
    Currency[2] lp2;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Currency yes = SetUpLibrary.deployCustomMintAndApproveCurrency(
            "YES",
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        );

        Currency no = SetUpLibrary.deployCustomMintAndApproveCurrency(
            "NO",
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        );

        Currency usdm = SetUpLibrary.deployCustomMintAndApproveCurrency(
            "USDM",
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        );
        lp1 = SetUpLibrary.sortTokensForLPPairing(yes, usdm);
        lp2 = SetUpLibrary.sortTokensForLPPairing(yes, usdm);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        deployCodeTo("PredictionMarketsAMM.sol:PredictionMarketsAMM", abi.encode(manager), flags);
        hook = PredictionMarketsAMM(flags);

        // Create the pool
        key = PoolKey(lp1[0], lp1[1], 500, 50, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);


        // Provide single-sided liquidity to the pool with YES
        IPoolManager.ModifyLiquidityParams memory singleSidedLiquidityParams = IPoolManager.ModifyLiquidityParams({tickLower: -23100, tickUpper: 0, liquidityDelta: 1e6, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(key, singleSidedLiquidityParams, ZERO_BYTES);

    }

    function test_afterInitialize() public {
        // Check that the hook is active
        assertEq(hook.isActive(), true);
        // Currency to MockERC20
        MockERC20 curr0 = MockERC20(Currency.unwrap(lp1[0]));
        console2.logString(curr0.symbol());

        MockERC20 curr1 = MockERC20(Currency.unwrap(lp1[1]));
        console2.logString(curr1.symbol());
        bool zeroForOne = true;


//        BalanceDelta d = swap(key, zeroForOne, 1e4, ZERO_BYTES); // should throw error
//        console2.logInt(BalanceDeltaLibrary.amount0(d));
//        console2.logInt(BalanceDeltaLibrary.amount1(d));
        // Check that the pool has the yes and no USDM tokens
    }
}
