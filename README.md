# Memediction
### **Powered by Uniswap v4 Hooks 🦄**
Unlimited Upside Tokenized
Prediction Market

Memediction is a prediction market that uses memecoins to forecast real life events. Each outcome is represented as an ERC20 token. The protocol uses single-sided liquidity pools on Uniswap to bootstrap liquidity for these ERC20 tokens.

ERC20 tokens offer traders the potential for unlimited upside, enhancing the overall trading experience.

At the end of the settlement date, a portion of the trading fees and the entire USD reserves of the losing pool will be distributed the holders of the winning outcome token. Eigenlayer AVS / Optimistic Oracles (e.g. UMA) will be used as an oracle to determine the event outcome.

---

## Set up

*requires [foundry](https://book.getfoundry.sh)*

```
forge install
forge test
```

### Local Development (Anvil)

Other than writing unit tests (recommended!), you can only deploy & test hooks on [anvil](https://book.getfoundry.sh/anvil/)

```bash
./setup-local.sh
```

To kill the anvil process, you may run `kill-anvil.sh`.