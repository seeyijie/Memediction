// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {QuestionData} from "../types/QuestionData.sol";

interface IOracle {
    function setQuestion(bytes32 questionID) external;
    function getQuestion(bytes32 questionID) external view returns (QuestionData memory);
}
