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
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

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

    bytes IPFS_BYTES = abi.encode("QmbU7wZ5UttANT56ZHo3CAxbpfYXbo8Wj9fSXkYunUDByP");
    bytes32 marketId; // Created marketId

    address USER_A = address(0xa);
    address USER_B = address(0xb);
    address USER_C = address(0xc);

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

    IOracle oracle;
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

    function _initializeMarketsHelperFn(bytes memory ipfsDetails, string[] memory outcomeNames)
        private
        returns (bytes32, PoolId[] memory, IPredictionMarket.Outcome[] memory, IOracle oracle)
    {
        IPredictionMarket.OutcomeDetails[] memory outcomeDetails =
            new IPredictionMarket.OutcomeDetails[](outcomeNames.length);
        for (uint256 i = 0; i < outcomeNames.length; i++) {
            outcomeDetails[i] = IPredictionMarket.OutcomeDetails(ipfsDetails, outcomeNames[i]);
        }

        (bytes32 marketId, PoolId[] memory poolIds, IPredictionMarket.Outcome[] memory pmOutcomes, IOracle oracle) =
            predictionMarketHook.initializeMarket(0, ipfsDetails, outcomeDetails);
        return (marketId, poolIds, pmOutcomes, oracle);
    }

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();

        // Deploy and set up YES, NO, and USDM tokens
        usdm = deployAndApproveCurrency("USDM");

        // Deploy the prediction market hook
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "PredictionMarketHook.sol:PredictionMarketHook", abi.encode(usdm, manager, modifyLiquidityRouter), flags
        );

        IERC20Minimal(Currency.unwrap(usdm)).approve(flags, type(uint256).max);
        predictionMarketHook = PredictionMarketHook(flags);
        // Created a ipfs detail from question.json
        bytes memory ipfsDetail = IPFS_BYTES;
        string[] memory outcomeNames = new string[](2);
        outcomeNames[0] = "YES";
        outcomeNames[1] = "NO";
        (bytes32 _marketId, PoolId[] memory poolIds, IPredictionMarket.Outcome[] memory outcomes, IOracle oracles) =
            _initializeMarketsHelperFn(ipfsDetail, outcomeNames);
        yes = outcomes[0].outcomeToken;
        no = outcomes[1].outcomeToken;
        oracle = oracles;
        marketId = _marketId;
        yesUsdmKey = predictionMarketHook.getPoolKeyByPoolId(poolIds[0]);
        noUsdmKey = predictionMarketHook.getPoolKeyByPoolId(poolIds[1]);
        yesUsdmLp = [yes, usdm];
        noUsdmLp = [no, usdm];
    }

    /**
     * Check oracle and pool manager state after the markets have been initialized
     * Ensure oracle is set up correctly and has the correct access controls
     */
    function test_initializeMarkets() public {
        // Check balances in poolmanager
        vm.assertEq(usdm.balanceOf(address(manager)), 0);
        vm.assertApproxEqRel(yes.balanceOf(address(manager)), 9.68181772459792e20, 1e9);
        vm.assertApproxEqRel(no.balanceOf(address(manager)), 9.68181772459792e20, 1e9);
        // ===== ORACLE CHECK =====
        // Check if oracle is set up correctly
        vm.assertEq(oracle.getOutcome(), 0);
        vm.assertEq(oracle.isOutcomeSet(), false);
        vm.assertEq(oracle.getIpfsHash(), IPFS_BYTES);
        // Attempted to set the outcome without the correct access control
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER_A));
        oracle.setOutcome(1);
        vm.prank(address(predictionMarketHook));
        oracle.setOutcome(1);
        vm.assertEq(oracle.getOutcome(), 1);
        vm.prank(address(predictionMarketHook));
        oracle.setOutcome(0); // Reset to 0
    }

    function test_getInitialPrice() public {
        // $1 = 1e18. $0.01 = 1e16
        // Current price should be approximately $0.01 at launch
        vm.assertApproxEqRel(predictionMarketHook.getPriceInUsdm(yesUsdmKey.toId()), 1e16, 1e15);
    }

    function testFuzz_getPriceInUsdm(PoolId poolId) public {
        // expect revert for InvalidPool(poolId)
        vm.expectRevert("Invalid pool ID, price=0");
        predictionMarketHook.getPriceInUsdm(poolId);
    }

    function test_claimWithoutResolution() public {
        vm.expectRevert("Market not resolved");
        predictionMarketHook.claim(marketId, 1e18);
    }

    function testFuzz_settle(bytes32 marketId, int16 outcome) public {
        vm.expectRevert();
        predictionMarketHook.settle(marketId, outcome);
    }

    function testFuzz_claim(bytes32 marketId, uint256 outcomeTokenAmountToClaim) public {
        vm.expectRevert();
        predictionMarketHook.claim(marketId, outcomeTokenAmountToClaim);
    }

    /**
     * This test ensures that the price of the YES keeps increasing as more USDM is swapped for YES
     */
    function test_multipleSwap() public {
        // Perform a test swap //
        // ---------------------------- //
        // Swap exactly 1e18 of USDM to YES
        // Swap from USDM to YES
        // ---------------------------- //

        // Start market to enable swapping
        predictionMarketHook.startMarket(marketId);

        // We want to swap USDM to YES, so take the opposite of the sorted pair
        bool isYesToken0 = yesUsdmLp[0].toId() == yes.toId();

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isYesToken0, // swap from USDM to YES
            amountSpecified: -1e18, // exactInput
            // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        (uint160 sqrtPriceX96Before, int24 tickBefore, uint24 protocolFeeBefore, uint24 lpFeeBefore) =
            StateLibrary.getSlot0(manager, yesUsdmKey.toId());
        uint160 beforePrice = TickMath.getSqrtPriceAtTick(tickBefore);
        uint256 realPriceBeforeSwap = predictionMarketHook.getPriceInUsdm(yesUsdmKey.toId());

        /**
         * takeClaims -> If true Mints ERC6909 claims, else ERC20 transfer out of the pool
         * settleUsingBurn -> If true, burns the input ERC6909, else transfers into the pool
         */
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yesUsdmKey, params, testSettings, ZERO_BYTES);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            StateLibrary.getSlot0(manager, yesUsdmKey.toId());
        uint160 afterPrice = TickMath.getSqrtPriceAtTick(tick);
        uint256 realPriceAfterSwaps = predictionMarketHook.getPriceInUsdm(yesUsdmKey.toId());
        uint160 changeInPrice = afterPrice - beforePrice;
        vm.assertEq(usdm.balanceOf(address(manager)), 1e18);

        vm.assertGt(changeInPrice, 0);
        vm.assertGt(realPriceAfterSwaps, realPriceBeforeSwap);
        IPoolManager.SwapParams memory secondSwapParams = IPoolManager.SwapParams({
            zeroForOne: !isYesToken0, // swap from USDM to YES
            amountSpecified: -2e18, // exactInput
            // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });
        (
            uint160 secondSwapSqrtPriceX96Before,
            int24 secondSwapTickBefore,
            uint24 secondSwapProtocolFeeBefore,
            uint24 secondSwapLpFeeBefore
        ) = StateLibrary.getSlot0(manager, yesUsdmKey.toId());
        uint160 secondSwapBeforePrice = TickMath.getSqrtPriceAtTick(secondSwapTickBefore);

        /**
         * takeClaims -> If true Mints ERC6909 claims, else ERC20 transfer out of the pool
         * settleUsingBurn -> If true, burns the input ERC6909, else transfers into the pool
         */
        PoolSwapTest.TestSettings memory secondSwapTestSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yesUsdmKey, secondSwapParams, secondSwapTestSettings, ZERO_BYTES);

        (
            uint160 secondSwapSqrtPriceX96After,
            int24 secondSwapTickAfter,
            uint24 secondSwapProtocolFeeAfter,
            uint24 secondSwapLpFeeAfter
        ) = StateLibrary.getSlot0(manager, yesUsdmKey.toId());

        uint160 secondSwapAfterPrice = TickMath.getSqrtPriceAtTick(secondSwapTickAfter);
        vm.assertEq(usdm.balanceOf(address(manager)), 3e18);
        vm.assertGt(secondSwapAfterPrice, secondSwapBeforePrice);
        vm.assertGt(afterPrice, beforePrice);
    }

    function approveCurrency(Currency c) internal {
        // Routers
        address[8] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        ];
        IERC20Minimal token = IERC20Minimal(Currency.unwrap(c));
        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], type(uint256).max);
        }
    }

    function test_settlement() public {
        // 1. Initialize markets //
        // 2. Swap USDM to YES //
        // 3. Swap USDM to NO //
        // 4. Settle the market //
        // 5. Check balances //

        // Transfer USDM to users
        IERC20Minimal(Currency.unwrap(usdm)).transfer(USER_A, 10000 ether);
        IERC20Minimal(Currency.unwrap(usdm)).transfer(USER_B, 10000 ether);
        IERC20Minimal(Currency.unwrap(usdm)).transfer(USER_C, 10000 ether);

        // We want to swap USDM to YES, so take the opposite of the sorted pair
        bool isYesToken0 = yesUsdmLp[0].toId() == yes.toId();
        bool isNoToken0 = noUsdmLp[0].toId() == no.toId();

        Currency yesToken = yesUsdmLp[isYesToken0 ? 0 : 1];
        Currency noToken = noUsdmLp[isNoToken0 ? 0 : 1];

        IPoolManager.SwapParams memory buyYesTokenSwapParams = IPoolManager.SwapParams({
            zeroForOne: !isYesToken0, // swap from USDM to YES
            amountSpecified: 1e18, // exactOutput of $YES
            // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        IPoolManager.SwapParams memory buyNoTokenSwapParams = IPoolManager.SwapParams({
            zeroForOne: !isNoToken0, // swap from USDM to NO
            amountSpecified: 1e18, // exactOutput of $NO
            // $NO token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $NO token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isNoToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        // Start market
        predictionMarketHook.startMarket(marketId);

        uint128 yesUsdmLiquidity = manager.getLiquidity(yesUsdmKey.toId());
        vm.assertEq(yesUsdmLiquidity, 0);

        // Swap USDM to YES
        vm.startPrank(USER_A);
        approveCurrency(usdm);
        MockERC20(Currency.unwrap(usdm)).approve(address(manager), usdm.balanceOf(USER_A));
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yesUsdmKey, buyYesTokenSwapParams, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Swap USDM to NO
        vm.startPrank(USER_B);
        approveCurrency(usdm);
        MockERC20(Currency.unwrap(usdm)).approve(address(manager), usdm.balanceOf(USER_B));
        swapRouter.swap(noUsdmKey, buyNoTokenSwapParams, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Swap USDM to NO
        vm.startPrank(USER_C);
        approveCurrency(usdm);
        MockERC20(Currency.unwrap(usdm)).approve(address(manager), usdm.balanceOf(USER_C));
        swapRouter.swap(noUsdmKey, buyNoTokenSwapParams, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Swap NO to USDM (partially sell)
        vm.startPrank(USER_B);
        approveCurrency(noToken);
        MockERC20(Currency.unwrap(noToken)).approve(address(manager), noToken.balanceOf(USER_B));
        IPoolManager.SwapParams memory sellNoTokenSwapParams = IPoolManager.SwapParams({
            zeroForOne: isNoToken0, // swap from NO to USDM
            amountSpecified: -1e17, // exactInput for 0.1 $NO sold
            sqrtPriceLimitX96: !isNoToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });
        swapRouter.swap(noUsdmKey, sellNoTokenSwapParams, testSettings, ZERO_BYTES);

        // User B attempting to settle even though he is not the creator
        vm.expectRevert("Only market creator can settle");
        predictionMarketHook.settle(marketId, 0);
        vm.stopPrank();

        bool isMarketResolved = predictionMarketHook.isMarketResolved(marketId);
        vm.assertEq(isMarketResolved, false);

        // Settle market, for $YES
        predictionMarketHook.settle(marketId, 0);

        isMarketResolved = predictionMarketHook.isMarketResolved(marketId);
        vm.assertEq(isMarketResolved, true);

        // Liquidity USDM should not be available in the losing ($NO) pool
        uint128 noUsdmLiquidity = manager.getLiquidity(noUsdmKey.toId());
        vm.assertEq(noUsdmLiquidity, 0);

        // Liquidity USDM should increase
        yesUsdmLiquidity = manager.getLiquidity(yesUsdmKey.toId());
        vm.assertEq(yesUsdmLiquidity, 0);

        // Check if circulatingSupply is correct, with market stage
        uint256 yesTokenCirculatingSupply = predictionMarketHook.outcomeTokenCirculatingSupply(yesUsdmKey.toId());
        uint256 noTokenCirculatingSupply = predictionMarketHook.outcomeTokenCirculatingSupply(noUsdmKey.toId());

        vm.assertEq(yesTokenCirculatingSupply, 1e18);
        vm.assertEq(noTokenCirculatingSupply, 19e17);
    }

    function test_settlement_withUsdm() public {
        // 1. Initializep markets //
        // 2. Swap USDM to YES //
        // 3. Swap USDM to NO //
        // 4. Settle the market //
        // 5. Check balances //

        // Transfer USDM to users
        IERC20Minimal(Currency.unwrap(usdm)).transfer(USER_A, 10000 ether);
        IERC20Minimal(Currency.unwrap(usdm)).transfer(USER_B, 10000 ether);
        IERC20Minimal(Currency.unwrap(usdm)).transfer(USER_C, 10000 ether);

        // We want to swap USDM to YES, so take the opposite of the sorted pair
        bool isYesToken0 = yesUsdmLp[0].toId() == yes.toId();
        bool isNoToken0 = noUsdmLp[0].toId() == no.toId();

        Currency yesToken = yesUsdmLp[isYesToken0 ? 0 : 1];
        Currency noToken = noUsdmLp[isNoToken0 ? 0 : 1];

        IPoolManager.SwapParams memory buyYesTokenSwapParams = IPoolManager.SwapParams({
            zeroForOne: !isYesToken0, // swap from USDM to YES
            amountSpecified: -5e18, // exactInput of $USDM
            // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        IPoolManager.SwapParams memory buyNoTokenSwapParams = IPoolManager.SwapParams({
            zeroForOne: !isNoToken0, // swap from USDM to NO
            amountSpecified: -1e18, // exactInput of $USDM
            // $NO token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $NO token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isNoToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        // Start market
        predictionMarketHook.startMarket(marketId);

        uint128 yesUsdmLiquidity = manager.getLiquidity(yesUsdmKey.toId());
        vm.assertEq(yesUsdmLiquidity, 0);

        // Swap USDM to YES
        vm.startPrank(USER_A);
        approveCurrency(usdm);
        MockERC20(Currency.unwrap(usdm)).approve(address(manager), usdm.balanceOf(USER_A));
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yesUsdmKey, buyYesTokenSwapParams, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Swap USDM to NO
        vm.startPrank(USER_B);
        approveCurrency(usdm);
        MockERC20(Currency.unwrap(usdm)).approve(address(manager), usdm.balanceOf(USER_B));
        swapRouter.swap(noUsdmKey, buyNoTokenSwapParams, testSettings, ZERO_BYTES);
        vm.stopPrank();

        // Swap USDM to NO
        vm.startPrank(USER_C);
        approveCurrency(usdm);
        MockERC20(Currency.unwrap(usdm)).approve(address(manager), usdm.balanceOf(USER_C));
        swapRouter.swap(noUsdmKey, buyNoTokenSwapParams, testSettings, ZERO_BYTES);
        vm.stopPrank();

        bool isMarketResolved = predictionMarketHook.isMarketResolved(marketId);
        vm.assertEq(isMarketResolved, false);

        // Settle market, for $YES
        predictionMarketHook.settle(marketId, 0);

        isMarketResolved = predictionMarketHook.isMarketResolved(marketId);
        vm.assertEq(isMarketResolved, true);

        // Liquidity USDM should not be available in the losing ($NO) pool
        uint128 noUsdmLiquidity = manager.getLiquidity(noUsdmKey.toId());
        vm.assertEq(noUsdmLiquidity, 0);

        // Liquidity USDM should increase
        yesUsdmLiquidity = manager.getLiquidity(yesUsdmKey.toId());
        vm.assertEq(yesUsdmLiquidity, 0);

        // Check reserves now
        uint256 usdmReservesInWinning = predictionMarketHook.usdmAmountInPool(yesUsdmKey.toId());
        uint256 usdmReservesInLosing = predictionMarketHook.usdmAmountInPool(noUsdmKey.toId());

        vm.assertApproxEqAbs(usdmReservesInWinning, 5e18, 1e2);
        vm.assertApproxEqAbs(usdmReservesInLosing, 2e18, 1e2);

        // Check market amount
        (,,,,, uint256 winningUsdmPoolAmount,) = predictionMarketHook.markets(marketId);
        vm.assertApproxEqAbs(winningUsdmPoolAmount, 7e18, 1e2);

        // claim fn
        uint256 usdmBalanceBefore = usdm.balanceOf(USER_A);

        vm.startPrank(USER_A);

        // Check amount to claim
        uint256 amountUsdmToClaim = predictionMarketHook.amountToClaim(marketId);
        vm.assertApproxEqAbs(amountUsdmToClaim, 7e18, 1e5);

        uint256 yesUserABalance = IERC20Minimal(Currency.unwrap(yes)).balanceOf(USER_A);
        IERC20Minimal(Currency.unwrap(yes)).approve(address(predictionMarketHook), yesUserABalance);
        predictionMarketHook.claim(marketId, yesUserABalance - 1e2);
        vm.stopPrank();

        uint256 usdmBalanceAfter = usdm.balanceOf(USER_A);
        vm.assertApproxEqAbs(usdmBalanceAfter - usdmBalanceBefore, 7e18, 1e5);

        // to check if it is indeed a very small number by adding 1e18 and
        // then using it to subtract by 1e18 to get a very small number
        uint deltaToExpand = 1e18;
        uint256 usdmBalanceExpanded = usdm.balanceOf(address(manager)) + deltaToExpand;

        // ensure that it is approximately equals to 0 after adding the deltaToExpand
        vm.assertApproxEqRel(usdmBalanceExpanded, deltaToExpand, 1e3);

        // Unable to claim again
        vm.expectRevert("Insufficient balance");
        predictionMarketHook.claim(marketId, yesUserABalance);

        // Loser who tried to claim
        vm.startPrank(USER_B);
        vm.expectRevert("Insufficient balance");
        predictionMarketHook.claim(marketId, 1e18);
    }

    function test_revertIfSwapOnNotStartedMarket() public {
        // get balance in poolManager
        uint256 balanceOfYes = IERC20Minimal(Currency.unwrap(yes)).balanceOf(address(manager));

        // We want to swap USDM to YES, so take the opposite of the sorted pair
        bool isYesToken0 = yesUsdmLp[0].toId() == yes.toId();

        // 1e16 = $0.01
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isYesToken0, // swap from USDM to YES
            amountSpecified: uintToInt(balanceOfYes - 1e3), // exactOutput, giving 1e3 as some form of buffer
        // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
        // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory swapTestSettings =
                            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.expectRevert(abi.encodePacked(PredictionMarketHook.SwapDisabled.selector, yesUsdmKey.toId()));
        swapRouter.swap(yesUsdmKey, params, swapTestSettings, ZERO_BYTES);
    }

    function test_swapAllToYes() public {
        // get balance in poolManager
        uint256 balanceOfYes = IERC20Minimal(Currency.unwrap(yes)).balanceOf(address(manager));

        // Start market to enable swapping
        predictionMarketHook.startMarket(marketId);

        // We want to swap USDM to YES, so take the opposite of the sorted pair
        bool isYesToken0 = yesUsdmLp[0].toId() == yes.toId();

        // 1e16 = $0.01
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isYesToken0, // swap from USDM to YES
            amountSpecified: uintToInt(balanceOfYes - 1e3), // exactOutput, giving 1e3 as some form of buffer
            // $YES token0 -> ticks go "->", so max slippage is MAX_TICK - 1
            // $YES token1 -> ticks go "<-", so max slippage is MIN_TICK + 1
            sqrtPriceLimitX96: isYesToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory swapTestSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yesUsdmKey, params, swapTestSettings, ZERO_BYTES);
        uint256 balanceOfYesAfterSwap = IERC20Minimal(Currency.unwrap(yes)).balanceOf(address(manager));

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            StateLibrary.getSlot0(manager, yesUsdmKey.toId());
        // Assert that ~$9.99 per YES
        vm.assertApproxEqRel(predictionMarketHook.getPriceInUsdm(yesUsdmKey.toId()), 1e19, 1e16);
    }

    // Helper function
    function uintToInt(uint256 _value) internal pure returns (int256) {
        require(_value <= uint256(type(int256).max), "Value exceeds int256 max limit");
        return int256(_value);
    }


}
