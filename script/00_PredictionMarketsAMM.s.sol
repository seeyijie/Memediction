// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {CentralisedOracle} from "../src/CentralisedOracle.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

contract PredictionMarketsAMMScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    address constant GOERLI_POOLMANAGER = address(0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b);

    CentralisedOracle oracle;

    function setUp() public {
        bytes memory eventIpfsHash = "ipfs://QmeSjSinHpPnmXmspMjwiXyN6zS4E9zccariGR3jxcaWtq/0";
        oracle = new CentralisedOracle(eventIpfsHash, msg.sender);
    }

    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(PredictionMarketHook).creationCode, abi.encode(address(GOERLI_POOLMANAGER))
        );

        // Deploy the hook using CREATE2
        vm.broadcast();
        bytes32 questionId = keccak256(abi.encode("Who will win the US Presidential election", "trump", "kamala"));
        PredictionMarketHook predMarkets =
            new PredictionMarketHook{salt: salt}(Currency.wrap(address(0)), IPoolManager(address(GOERLI_POOLMANAGER)));
        require(address(predMarkets) == hookAddress, "PredictionMarketsAMMScript: hook address mismatch");
    }
}
