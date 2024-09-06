// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracle {
    function isOutcomeSet() external view returns (bool);
    function getOutcome() external view returns (int);
}
