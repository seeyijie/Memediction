// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

import {IOracle} from "./interface/IOracle.sol";
import {QuestionData} from "./types/QuestionData.sol";

contract PredictionMarketsAMM is BaseHook {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    IOracle public oracle;

    // @notice Hash of the question content
    // keccak256(abi.encode(question, outcome1, outcome2, ...))
    bytes32 public questionId;

    constructor(IPoolManager _poolManager, IOracle _oracle, bytes32 _questionId) BaseHook(_poolManager) {
        oracle = _oracle;
        questionId = _questionId;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
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
    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata) external override returns (bytes4) {
        QuestionData memory question = oracle.getQuestion(questionId);
        require(question.creationTimestamp != 0, "PredictionMarketsAMM: Question creation timestamp not set");
        require(question.creator != address(0), "PredictionMarketsAMM: Question creator not set");
        require(question.outcome == bytes32(0), "PredictionMarketsAMM: Outcome must be 0x0");
        return (BaseHook.beforeInitialize.selector);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // check oracle for data
        bytes32 outcome = oracle.getQuestion(questionId).outcome;
        if (outcome == bytes32(0)) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        revert("PredictionMarketsAMM: Outcome already set");
    }
}
