// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {QuestionData} from "./types/QuestionData.sol";
import {IOracle} from "./interface/IOracle.sol";

// TODO: Add access control to the contract
contract PermissionedOracle is IOracle {
    // @notice Hash of the question content
    // keccak256(abi.encode(question, outcome1, outcome2, ...))
    // questionId => QuestionData
    mapping(bytes32 questionId => QuestionData) public questions;

    function setQuestion(bytes32 questionID) external {
        uint256 timestamp = block.timestamp;
        questions[questionID] = QuestionData(timestamp, msg.sender, bytes32(0));
    }

    function setOutcome(bytes32 questionID, bytes32 outcome) external {
        questions[questionID].outcome = outcome;
    }

    function getQuestion(bytes32 questionID) external view override returns (QuestionData memory) {
        return questions[questionID];
    }
}
