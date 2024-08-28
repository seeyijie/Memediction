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

    PredictionMarketsAMM yesUsdmHook;
    PredictionMarketsAMM noUsdmHook;
    PoolId yesUsdmPoolId;
    PoolKey yesUsdmKey;
    PoolId noUsdmPoolId;
    PoolKey noUsdmKey;

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
            address(nestedActionRouter.executor()),
            1e27
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
            address(nestedActionRouter.executor()),
            1e27
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
            address(nestedActionRouter.executor()),
            1e27
        );
        lp1 = SetUpLibrary.sortTokensForLPPairing(yes, usdm);
        lp2 = SetUpLibrary.sortTokensForLPPairing(no, usdm);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        deployCodeTo("PredictionMarketsAMM.sol:PredictionMarketsAMM", abi.encode(manager), flags);
        yesUsdmHook = PredictionMarketsAMM(flags);

        // Deploy the hook to an address with the correct flags
        address flags2 = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 145) // Namespace the hook to avoid collisions
        );
        deployCodeTo("PredictionMarketsAMM.sol:PredictionMarketsAMM", abi.encode(manager), flags2);

        noUsdmHook = PredictionMarketsAMM(flags2);

        // 1. Initialize the pool with YES-USDM
        yesUsdmKey = PoolKey(lp1[0], lp1[1], 500, 60, IHooks(yesUsdmHook));
        yesUsdmPoolId = yesUsdmKey.toId();
        manager.initialize(yesUsdmKey, SQRT_PRICE_1_2, ZERO_BYTES);

        // Provide single-sided liquidity to the pool with YES
        IPoolManager.ModifyLiquidityParams memory singleSidedLiquidityParams = IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e6, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(yesUsdmKey, singleSidedLiquidityParams, ZERO_BYTES);

        // 2. Initialize the pool with NO-USDM
        noUsdmKey = PoolKey(lp2[0], lp2[1], 500, 60, IHooks(noUsdmHook));
        noUsdmPoolId = yesUsdmKey.toId();
        manager.initialize(noUsdmKey, SQRT_PRICE_1_2, ZERO_BYTES);

        // Provide single-sided liquidity to the pool with NO
        modifyLiquidityRouter.modifyLiquidity(noUsdmKey, singleSidedLiquidityParams, ZERO_BYTES);
    }

    function test_afterInitialize() public {
        // Check that the hook isActive state is true
        assertEq(yesUsdmHook.isActive(), true);
        assertEq(noUsdmHook.isActive(), true);

        // Check that the poolManager has YES and NO tokens

        // 1. Check for $YES and zero $USDM in YES-USDM
        MockERC20 curr0 = MockERC20(Currency.unwrap(lp1[0]));
        console2.logString(curr0.symbol()); // YES

        MockERC20 curr1 = MockERC20(Currency.unwrap(lp1[1]));
        console2.logString(curr1.symbol()); // USDM
        bool zeroForOne = false;

        console2.logUint(curr0.balanceOf(address(manager)));
        console2.logUint(curr1.balanceOf(address(manager)));
        assertGt(curr0.balanceOf(address(manager)), 0);
        assertEq(curr1.balanceOf(address(manager)), 0);

        // 2. Check for $NO and zero $USDM in YES-USDM
        MockERC20 currA = MockERC20(Currency.unwrap(lp2[0]));
        console2.logString(currA.symbol()); // NO

        MockERC20 currB = MockERC20(Currency.unwrap(lp2[1]));
        console2.logString(currB.symbol()); // USDM
        assertGt(currA.balanceOf(address(manager)), 0);
        assertEq(currB.balanceOf(address(manager)), 0);
    }
}
