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
import {PredictionMarketsAMM} from "../src/PredictionMarketsAMM.sol";
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
contract PredictionMarketsAMMTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    PredictionMarketsAMM predictionMarketHook;
    PredictionMarket market;

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

    function _initializePool(Currency outcomeToken, Currency usdm, Currency[2] storage lpPair) private {
        PoolKey memory poolKey = PoolKey(lpPair[0], lpPair[1], 0, TICK_SPACING, predictionMarketHook);
        bool isToken0 = lpPair[0].toId() == outcomeToken.toId();

        (int24 lowerTick, int24 upperTick) = getTickRange(isToken0);
        int24 initialTick = isToken0 ? lowerTick - TICK_SPACING : upperTick + TICK_SPACING;
        uint160 initialSqrtPricex96 = TickMath.getSqrtPriceAtTick(initialTick);
        manager.initialize(poolKey, initialSqrtPricex96, ZERO_BYTES);
    }

    function initializeAndProvideLiquidity(Currency outcomeToken, Currency usdm, Currency[2] storage lpPair)
        private
        returns (PoolKey memory)
    {
        PoolKey memory poolKey = PoolKey(lpPair[0], lpPair[1], 0, TICK_SPACING, predictionMarketHook);
        bool isToken0 = lpPair[0].toId() == outcomeToken.toId();
        (int24 lowerTick, int24 upperTick) = getTickRange(isToken0);
        int24 initialTick = isToken0 ? lowerTick - TICK_SPACING : upperTick + TICK_SPACING;
        uint160 initialSqrtPricex96 = TickMath.getSqrtPriceAtTick(initialTick);
        manager.initialize(poolKey, initialSqrtPricex96, ZERO_BYTES);
        IPoolManager.ModifyLiquidityParams memory singleSidedLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTick,
            tickUpper: upperTick,
            liquidityDelta: 100e18,
            salt: 0
        });

        uint256 beforeBalance = outcomeToken.balanceOfSelf();
        modifyLiquidityRouter.modifyLiquidity(poolKey, singleSidedLiquidityParams, ZERO_BYTES);
        uint256 afterBalance = outcomeToken.balanceOfSelf();

        /**
         * Calculations (USDM-TOKEN)
         * P > P_b
         * Liquidity Delta = yDelta / (sqrt(P_b) - sqrt(P_a))
         * yDelta = lDelta * (sqrt(P_b) - sqrt(P_a))
         * yDelta = 100e18 * ( sqrt(1.0001^46050) - sqrt(1.0001^(-23030)) )
         * yDelta = 9.68181772459792e20
         */

        // Accurate up to (20 - 12 = 8) decimal places
        assertApproxEqAbs(beforeBalance - afterBalance, 9681817724e11, 1e12);
        return poolKey;
    }

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

    function _initializeMarkets(bytes memory ipfsDetails, string[] memory outcomeNames) private {
        IPredictionMarket.OutcomeDetails[] memory outcomeDetails =
            new IPredictionMarket.OutcomeDetails[](outcomeNames.length);
        for (uint256 i = 0; i < outcomeNames.length; i++) {
            console2.log("Outcome names: ", outcomeNames[i]);
            outcomeDetails[i] = IPredictionMarket.OutcomeDetails(ipfsDetails, outcomeNames[i]);
        }

        (PoolId[] memory poolIds, IPredictionMarket.Outcome[] memory o) = market.initializeMarket(0, ipfsDetails, outcomeDetails);
    }

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();

        // Deploy and set up YES, NO, and USDM tokens
        usdm = deployAndApproveCurrency("USDM");

        // Deploy the prediction market hook
        address flags = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        deployCodeTo("PredictionMarketsAMM.sol:PredictionMarketsAMM", abi.encode(usdm, manager), flags);

        IERC20Minimal(Currency.unwrap(usdm)).approve(flags, type(uint256).max);

        market = PredictionMarketsAMM(flags);
        // Created a ipfs detail from question.json
        bytes memory ipfsDetail = abi.encode("QmbU7wZ5UttANT56ZHo3CAxbpfYXbo8Wj9fSXkYunUDByP");
        string[] memory outcomeNames = new string[](2);
        outcomeNames[0] = "YES";
        outcomeNames[1] = "NO";
        _initializeMarkets(ipfsDetail, outcomeNames);
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

    //    function test_swap() public {
    //        // Perform a test swap //
    //        // ---------------------------- //
    //        // Swap exactly 1e18 of USDM to YES
    //        // Swap from USDM to YES
    //        // ---------------------------- //
    //
    //        // We want to swap USDM to YES, so take the opposite of the sorted pair
    //        bool isYesToken0 = yesUsdmLp[0].toId() == yes.toId();
    //
    //        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //            zeroForOne: !isYesToken0, // swap from USDM to YES
    //            amountSpecified: -1e18, // exactInput
    //            // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
    //            // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
    //            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
    //        });
    //
    //        /**
    //         * takeClaims -> If true Mints ERC6909 claims, else ERC20 transfer out of the pool
    //         * settleUsingBurn -> If true, burns the input ERC6909, else transfers into the pool
    //         */
    //        PoolSwapTest.TestSettings memory testSettings =
    //            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
    //
    //        swapRouter.swap(yesUsdmKey, params, testSettings, ZERO_BYTES);
    //
    //        // Assert ERC6909 currency0.toId() balances
    //    }
}
