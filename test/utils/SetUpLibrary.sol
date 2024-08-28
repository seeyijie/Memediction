// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

library SetUpLibrary {
    // helper methods
    function deployCustomTokens(string memory symbol, uint256 totalSupply) internal returns (MockERC20 token) {
        MockERC20 token = new MockERC20(symbol, symbol, 18);
        token.mint(address(this), totalSupply);
        return token;
    }

    function deployCustomMintAndApproveCurrency(
        string memory symbol,
        address swapRouter,
        address swapRouterNoChecks,
        address modifyLiquidityRouter,
        address modifyLiquidityNoChecks,
        address donateRouter,
        address takeRouter,
        address claimsRouter,
        address nestedActionRouterExecutor,
        uint256 totalSupply
    ) external returns (Currency currency) {
        MockERC20 token = deployCustomTokens(symbol, totalSupply);

        address[8] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouterExecutor)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }

    function sortTokensForLPPairing(Currency _currencyA, Currency _currencyB) external returns (Currency[2] memory) {
        (Currency currency0, Currency currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(_currencyA)), MockERC20(Currency.unwrap(_currencyB)));
        Currency[2] memory currencies = [currency0, currency1];
        return currencies;
    }
}
