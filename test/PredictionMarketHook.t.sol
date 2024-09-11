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
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SetUpLibrary} from "./utils/SetUpLibrary.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IOracle} from "../src/interface/IOracle.sol";
import {CentralisedOracle} from "../src/CentralisedOracle.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {IPredictionMarket} from "../src/interface/IPredictionMarket.sol";

/**
 * What is liquidity delta?
 *
 *  https://uniswap.org/whitepaper-v3.pdf
 *  Section 6.29 & 6.30
 *
 *  Definition:
 *  - P_a -> lower price range
 *  - P_b -> upper price range
 *  - P -> current price
 *  - lDelta -> liquidity delta
 *
 *  3 scenarios when providing liquidity to calculate liquidity delta:
 *
 *  1. P < P_a
 *
 *  lDelta = xDelta / (1/sqrt(P_a) - 1/sqrt(P_b))
 *
 *  2. P_a < P < P_b
 *
 *  lDelta = xDelta / (1/sqrt(P) - 1/sqrt(P_b)) = yDelta / (sqrt(P) - sqrt(P_a))
 *
 *  3. P > P_b
 *
 *  lDelta = yDelta / (sqrt(P_b) - sqrt(P_a))
 */
contract PredictionMarketHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using TickMath for int24;

    PredictionMarketHook predictionMarketHook;
//    PredictionMarket market;

    PoolKey yesUsdmKey;
    PoolKey noUsdmKey;

    // Sorted YES-USDM
    Currency[2] yesUsdmLp;
    // Sorted NO-USDM
    Currency[2] noUsdmLp;

    // Currencies for the test
    Currency yes;
    Currency no;
    Currency usdm;

    // Smaller ticks have more precision, but cost more gas (vice-versa)
    int24 private TICK_SPACING = 10;

    function deployAndApproveCurrency(string memory name) private returns (Currency) {
        return SetUpLibrary.deployCustomMintAndApproveCurrency(
            name,
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            1e18 * 1e9
        );
    }

    function _initializeMarkets(bytes memory ipfsDetails, string[] memory outcomeNames) private returns (PoolId[] memory, IPredictionMarket.Outcome[] memory) {
        IPredictionMarket.OutcomeDetails[] memory outcomeDetails =
            new IPredictionMarket.OutcomeDetails[](outcomeNames.length);
        for (uint256 i = 0; i < outcomeNames.length; i++) {
            console2.log("Outcome names: ", outcomeNames[i]);
            outcomeDetails[i] = IPredictionMarket.OutcomeDetails(ipfsDetails, outcomeNames[i]);
        }

        (PoolId[] memory poolIds, IPredictionMarket.Outcome[] memory o) = predictionMarketHook.initializeMarket(0, ipfsDetails, outcomeDetails);
        return (poolIds, o);
    }

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();

        // Deploy and set up YES, NO, and USDM tokens
        usdm = deployAndApproveCurrency("USDM");

        // Deploy the prediction market hook
        address flags = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        deployCodeTo("PredictionMarketHook.sol:PredictionMarketHook", abi.encode(usdm, manager), flags);

        IERC20Minimal(Currency.unwrap(usdm)).approve(flags, type(uint256).max);
        predictionMarketHook = PredictionMarketHook(flags);
        // Created a ipfs detail from question.json
        bytes memory ipfsDetail = abi.encode("QmbU7wZ5UttANT56ZHo3CAxbpfYXbo8Wj9fSXkYunUDByP");
        string[] memory outcomeNames = new string[](2);
        outcomeNames[0] = "YES";
        outcomeNames[1] = "NO";
        (PoolId[] memory poolIds, IPredictionMarket.Outcome[] memory outcomes) = _initializeMarkets(ipfsDetail, outcomeNames);
        yes = outcomes[0].outcomeToken;
        no = outcomes[1].outcomeToken;
        yesUsdmKey = predictionMarketHook.getPoolKeyByPoolId(poolIds[0]);
        noUsdmKey = predictionMarketHook.getPoolKeyByPoolId(poolIds[1]);
        yesUsdmLp = [yes, usdm];
        noUsdmLp = [no, usdm];
        console2.log("YES: ", yes.toId());
        console2.log("NO: ", no.toId());
    }

    function test_initialize() public {
        // Do nothing, just to run "setup" assertions
        vm.assertEq(usdm.balanceOf(address(manager)), 0);
        // 1e18 = 1% tolerance
        vm.assertApproxEqRel(yes.balanceOf(address(manager)), 9.68181772459792e20, 1e9);
        vm.assertApproxEqRel(no.balanceOf(address(manager)), 9.68181772459792e20, 1e9);
        console2.log("YES balance: ", yes.balanceOf(address(manager)));
        console2.log("NO balance: ", no.balanceOf(address(manager)));
    }

    function test_swap() public {
        // Perform a test swap //
        // ---------------------------- //
        // Swap exactly 1e18 of USDM to YES
        // Swap from USDM to YES
        // ---------------------------- //

        console2.log("=====BEFORE SWAP=====");
        console2.log("YES balance: ", yes.balanceOf(address(manager)));
        console2.log("NO balance: ", no.balanceOf(address(manager)));
        console2.log("USDM balance: ", usdm.balanceOf(address(manager)));


        // We want to swap USDM to YES, so take the opposite of the sorted pair
        bool isYesToken0 = yesUsdmLp[0].toId() == yes.toId();
        console2.log("yesUsdmLp[0].toId()", yesUsdmLp[0].toId());
        console2.log("yesUsdmLp[1].toId()", yesUsdmLp[1].toId());
        console2.log("noUsdmLp[0].toId()", noUsdmLp[0].toId());
        console2.log("noUsdmLp[1].toId()", noUsdmLp[1].toId());

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isYesToken0, // swap from USDM to YES
            amountSpecified: -1e18, // exactInput
            // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        (uint160 sqrtPriceX96Before, int24 tickBefore, uint24 protocolFeeBefore, uint24 lpFeeBefore) = StateLibrary.getSlot0(manager, yesUsdmKey.toId());
        console2.log("Tick: ", tickBefore);
        console2.log("sqrtPrice based on tick:", TickMath.getSqrtPriceAtTick(tickBefore));
        uint160 beforePrice = TickMath.getSqrtPriceAtTick(tickBefore);

        /**
            * takeClaims -> If true Mints ERC6909 claims, else ERC20 transfer out of the pool
            * settleUsingBurn -> If true, burns the input ERC6909, else transfers into the pool
            */
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        swapRouter.swap(yesUsdmKey, params, testSettings, ZERO_BYTES);
        console2.log("=====AFTER SWAP=====");

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, yesUsdmKey.toId());
        console2.log("Tick: ", tick);
        console2.log("sqrtPrice based on tick:", TickMath.getSqrtPriceAtTick(tick));
        uint160 afterPrice = TickMath.getSqrtPriceAtTick(tick);
        uint160 changeInPrice = afterPrice - beforePrice;
        uint256 yDelta = changeInPrice * 100e18;
        console2.log("yDelta: ", yDelta);
        /**
        *  L = yDelta / (sqrt(P_b) - sqrt(P_a)) = 9.68181772459792e20 / (sqrt(1.0001^46050) - sqrt(1.0001^(-23030))) = 100e18
        *  delta_sqrt(P) = 1e18 / 100e18 = 0.01
        *  xDelta = (1 / 0.01)(100e18) = 1e18
        *  yDelta = L . delta_sqrt(P) = 100e18 * 0.01 = 1e18
        *
        *  price_diff = (amount_in * q96) // liq
        *  price_next = sqrtp_cur + price_diff

        * amt in = 100e18(sqrt(P_b) - sqrt(P_a) / (sqrt(P_b) . sqrt(P_a))
        * 1
        * amt out = 100e18(sqrt(P_b) - sqrt(P_a)
        */

//        vm.assertApproxEqRel(yes.balanceOf(address(manager)), 1e18, 1e9);
        vm.assertEq(usdm.balanceOf(address(manager)), 1e18);
        // Assert ERC6909 currency0.toId() balances
//        1.001
        console2.log("YES balance: ", yes.balanceOf(address(manager)));
        console2.log("NO balance: ", no.balanceOf(address(manager)));
        console2.log("USDM balance: ", usdm.balanceOf(address(manager)));
    }
}
