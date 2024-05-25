### Presentation of the DCA Smart Contract

Our smart contract implements a Dollar Cost Averaging (DCA) strategy. This strategy allows regular investments of an amount in tokenIn, which will be converted to tokenOut at defined intervals (e.g., daily or weekly). This enables a passive and automatic investment approach.

### Functionality of the Main Functions

1. **`createOrder` Function**
   - **Arguments**: Takes the order values and the `paraswapArgs` structure as input.
   - **Role**: Creates the user's order, executes the order for the first time, and sets up an automated task with Gelato for future executions.

2. **`executeOrder` Function**
   - **Arguments**: Takes the order ID, Gelato fees, and two `paraswapArgs` structures (one for the order swap and one for the equivalent of 0.1 FTM swap for Gelato fees).
   - **Role**: Executes the order swap according to the ID (and pays Gelato fees).

3. **`editOrder`, `stopOrder`, `restartOrder` Functions**
   - **Role**: Allow interaction with the existing order. The function names are self-explanatory.

### External Integrations for the DCA Functionality

- **Gelato**
  - **Role**: Gelato is used to execute tasks that call the `executeOrder` function of the smart contract at regular intervals (according to the period defined in the order).
  - **Functionality**: A TypeScript script, hosted on IPFS, retrieves the values from ParaSwap based on the parameters (tokenIn, tokenOut, amount, etc.). These values are then placed into the `paraswapArgs` structure, necessary for `executeOrder`.
  - **Self-Payment**: Gelato uses a selfpay mechanism, for which 0.1 FTM is swapped to pay Gelato's fees, managed within `executeOrder`.

- **ParaSwap**
  - **Role**: ParaSwap is used to perform the swaps. It supports different types of swaps (SimpleSwap, MultiSwap, MegaSwap), which is why functions leading to a swap use a `paraswapArgs` structure.

In summary, our DCA smart contract allows for automated and regular investments through the integration of Gelato for task management and ParaSwap for swap execution. The main functions handle the creation, execution, and modification of orders, providing a simple and effective investment solution.
