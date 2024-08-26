// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

/**
 * @title CustomDeployers
 * @notice Custom deployers for the Uniswap V4 core contracts
 */
contract CustomDeployers is Deployers {
    function deployCustomTokens(string memory symbol, uint256 totalSupply) internal returns (MockERC20 token) {
        MockERC20 token = new MockERC20(symbol, symbol, 18);
        token.mint(address(this), totalSupply);
        return token;
    }

    function deployCustomMintAndApproveCurrency(string memory symbol) external returns (Currency currency) {
        MockERC20 token = deployCustomTokens(symbol, 2 ** 255);

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

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }

    function sortTokensForLPPairing(Currency _currencyA, Currency _currencyB) external returns (Currency[2] memory) {
        (currency0, currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(_currencyA)), MockERC20(Currency.unwrap(_currencyB)));
        Currency[2] memory currencies = [currency0, currency1];
        return currencies;
    }
}
