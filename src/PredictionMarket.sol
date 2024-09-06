// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IOracle} from "./interface/IOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

// Finite State Machine
enum Stage {
    CREATED, // Created but not started
    STARTED, // Event has started (open to buy / sell)
    RESOLVED, // Market resolved
    ENDED, // Payouts distributed
    CANCELED
}

struct Outcome {
    Currency outcomeToken; // Currency used instead of ERC20
    bytes ipfsDetailsHash; // Store description, image, etc in JSON format
}

struct Event {
    Currency collateralToken;

    string question; // Revisit to restrict length (gas fees)
    bool isOutcomeSet;
    int16 outcomeResolution; // -1 by default

    Outcome[] outcomes; // Store outcome tokens in array

    // Store v4 poolIds based on outcome resolution index
    PoolId[] lpPools;
}

struct Market {
    Stage stage;
    address creator;
    uint createdAtBlock;
    Event eventContract;
    uint24 fee; // Reflected in LP pool fee
}

contract PredictionMarket {
    Currency immutable public usdm;

    mapping(bytes32 => Market) public markets;

    constructor(Currency _usdm) {
        usdm = _usdm;
    }

    function initializeMarket(uint24 _fee, string calldata _question, Currency _collateralToken, Outcome[] calldata _outcomes) virtual external {}

    function startEvent(uint _marketId) virtual external {}
}