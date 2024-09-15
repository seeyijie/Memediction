// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolTakeTest} from "v4-core/src/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPredictionMarket} from "../src/interface/IPredictionMarket.sol";
import {IOracle} from "../src/interface/IOracle.sol";
import {console} from "forge-std/console.sol";

contract HookMiningSample is Script {
    PoolManager manager = PoolManager(0x5FbDB2315678afecb367f032d93F642f64180aa3);
    PoolSwapTest swapRouter = PoolSwapTest(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512);
    PoolModifyLiquidityTest modifyLiquidityRouter = PoolModifyLiquidityTest(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0);

    Currency usdm;
    Currency yes;
    Currency no;

    PoolKey key;
    PredictionMarketHook hook;

    address constant USER_A = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function approve(MockERC20 token) private returns (Currency currency) {
        address[3] memory toApprove = [address(swapRouter), address(modifyLiquidityRouter), address(manager)];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], type(uint256).max);
        }
        return Currency.wrap(address(token));
    }

    function setUp() public {
        vm.startBroadcast();
        MockERC20 usdmToken = new MockERC20("USDM", "USDM", 18);
        usdm = Currency.wrap(address(usdmToken));
        usdmToken.mint(USER_A, 1000e18);
        console.log("Balance of user A:", usdmToken.balanceOf(USER_A));

        uint160 flags =  uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PredictionMarketHook).creationCode, abi.encode(usdm, manager));

        hook = new PredictionMarketHook{salt: salt}(usdm, manager);
        approve(usdmToken);
        require(hookAddress == address(hook), "wrong address");
        console.log("hookAddress", hookAddress);
        vm.stopBroadcast();
    }

    function run() public {
        vm.startBroadcast();
        bytes memory IPFS_DETAIL = abi.encode("QmbU7wZ5UttANT56ZHo3CAxbpfYXbo8Wj9fSXkYunUDByP");
        IPredictionMarket.OutcomeDetails memory yesDetails =
            IPredictionMarket.OutcomeDetails({ipfsDetails: IPFS_DETAIL, name: "Yes"});
        IPredictionMarket.OutcomeDetails memory noDetails =
            IPredictionMarket.OutcomeDetails({ipfsDetails: IPFS_DETAIL, name: "No"});

        IPredictionMarket.OutcomeDetails[] memory outcomeDetails = new IPredictionMarket.OutcomeDetails[](2);
        outcomeDetails[0] = yesDetails;
        outcomeDetails[1] = noDetails;
        (bytes32 marketId, PoolId[] memory lpPools, IPredictionMarket.Outcome[] memory outcomes, IOracle oracle) = hook.initializeMarket(0, IPFS_DETAIL, outcomeDetails);

        // Print out poolId
        console.log("lpPools");
        for (uint256 i = 0; i < lpPools.length; i++) {
            console.logBytes32(PoolId.unwrap(lpPools[i]));
        }

        // Print out outcomes
        console.log("outcomes");
        for (uint256 i = 0; i < outcomes.length; i++) {
            console.logAddress(Currency.unwrap(outcomes[i].outcomeToken));
            console.logBytes(outcomes[i].details.ipfsDetails);
        }

        // Print out oracle
        console.log("oracle");
        console.logAddress(address(oracle));

        vm.stopBroadcast();
    }
}
