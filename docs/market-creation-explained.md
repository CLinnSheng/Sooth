# Market Creation: Code Walkthrough

A beginner-friendly explanation of the market creation contracts in `contracts/`. Solidity concepts are explained as they come up.

Design decisions referenced as **Q1–Q8** come from the team's market creation plan:

| # | Decision |
|---|---|
| Q1 | Each market is a separate **clone** contract (EIP-1167) |
| Q2 | Token IDs are **hashed**: `keccak256(abi.encode(marketId, outcome))` |
| Q3 | Markets start at **50/50**; `initialYesProbabilityBps` exists in the interface for later |
| Q4 | The arbitrator **may** be the creator (risk documented in the threat model) |
| Q5 | Full spec JSON emitted in `MarketCreated`; only its **hash** is stored, computed by the factory |
| Q6 | **Admin-only** creation, so no creator bond yet |
| Q7 | Minimum liquidity is a factory constant. The fee (flat 1%) and resolution window (7 days) are constants in `Market` |

Run everything from `contracts/`: `forge build`, `forge test`.

---

## 1. The big picture

Picture a small prediction-market company. Each file plays one part:

| Real world | In the code |
|---|---|
| The **front desk**: only staff can open a new market | `MarketFactory` |
| A **market** (one question, e.g. "Will BTC exceed $150k?") | `Market`, one separate copy per question |
| **Play money** everyone bets with | `MockUSDC` |
| **Betting slips** (a YES slip or a NO slip) | `OutcomeToken` |
| The **slip numbering rule** (which number is which slip) | `OutcomeTokenId` |
| **Job descriptions** everyone agrees on | the 3 files in `interfaces/` |
| **Quality checks** | `MarketFactory.t.sol` (tests) |
| The **setup crew** that builds the company on day one | `DeployMarketFactory.s.sol` |

### How the files connect

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │  DeployMarketFactory.s.sol      (run once, builds everything)         │
 └──────────┬──────────────────────────────────────────┬────────────────┘
            │ deploys                                  │ deploys (test chains only)
            ▼                                          ▼
 ┌─────────────────────────┐                     ┌──────────────┐
 │     MarketFactory       │                     │  MockUSDC    │
 │  "front desk"           │                     │ play money   │
 │  - only admin can use   │                     └──────┬───────┘
 │  - checks every input   │                            │
 └───┬───────────────┬─────┘                            │ USDC goes
     │ deploys once  │ deploys once                     │ straight from
     │ (constructor) │ (constructor)                    │ admin to market
     ▼               ▼                                  │
 ┌──────────────┐  ┌─────────────────────┐              │
 │ OutcomeToken │  │ Market (original    │              │
 │ one shared   │  │ copy = "template")  │              │
 │ pile of YES/ │  └─────────┬───────────┘              │
 │ NO slips     │            │ createMarket() makes     │
 └──────▲───────┘            │ a cheap clone per        │
        │                    ▼ question                 │
        │  mints slips  ┌──────────┐ ┌──────────┐       │
        └───────────────┤ Market 1 │ │ Market 2 │ ◀─────┘
          (only for its │ (clone)  │ │ (clone)  │  each holds its own USDC
           own slips)   └──────────┘ └──────────┘

 Used by everything:   OutcomeTokenId.sol  (how a slip number is calculated)
 Agreed by everyone:   IMarketFactory / IMarket / IOutcomeToken  (the interfaces)
```

The factory builds one `OutcomeToken` and one template `Market` at the start. After that, every new question becomes a cheap **clone** of the template, which costs far less than deploying a full contract each time.

### What each file does

| File | What it does in one sentence | Who uses it |
|---|---|---|
| `src/mocks/MockUSDC.sol` | Fake dollars anyone can print, with 6 decimals like real USDC | Everyone |
| `src/libraries/OutcomeTokenId.sol` | The formula `hash(marketId, YES or NO)` that gives each slip type a unique number | Market, OutcomeToken, tests |
| `src/interfaces/IMarketFactory.sol` | Lists the inputs, errors and the `MarketCreated` announcement for the factory | Frontend, teammates |
| `src/interfaces/IMarket.sol` | Same for a market: states (Open/Closed/…), settings, prices | Frontend, factory |
| `src/interfaces/IOutcomeToken.sol` | Same for the slip contract | Markets, factory |
| `src/OutcomeToken.sol` | One shared contract holding every YES/NO slip. Only market #1 can create or destroy market #1's slips | Markets, factory |
| `src/Market.sol` | One question: saves its rules once and never changes them, reports Open/Closed from the clock, shows the YES/NO price | Factory (setup), users (reads) |
| `src/MarketFactory.sol` | The only way to create a market: checks admin, checks inputs, builds the clone, moves the money, announces it | The admin |
| `test/MarketFactory.t.sol` | 40 automatic checks, including attempts to cheat | Developers (`forge test`) |
| `script/DeployMarketFactory.s.sol` | Builds the whole system on a chain, with safety guards | Developers, once per network |

### The key idea: slips and money always match

```
  100 USDC in the market's vault
        ↕  always at least as much as the slips that exist
  100 YES slips  +  100 NO slips   (held by the market itself)
```

One YES slip and one NO slip together are worth exactly 1 USDC, because one of them will win and pay 1 USDC. So the vault always has enough money to pay any winner. Because the pool starts equal (100 / 100), the price starts at 50% YES and 50% NO.

### What the safety rules protect against

| Rule | Stops this |
|---|---|
| Only the admin can create markets | Strangers filling the site with junk markets |
| Settings have no "change" button | The creator quietly changing the rules after people bet |
| Only the factory can set up a new market | A stranger grabbing a fresh market and making themselves the judge |
| Only the owning market can create its slips | One buggy market printing slips for another market |
| Market checks it really received the USDC | Slips with no money behind them |
| Factory hashes the spec, full text in the creation event | Anyone can verify the rules were never swapped, without trusting the creator's hash or an off-chain host |

### What is not built yet

Markets support constant-product YES/NO trading with 1% fees accrued for the platform wallet recorded as creator. After trading closes, anyone can call `withdrawFees()` to pay the creator. Resolution, redemption, and liquidity withdrawal are not implemented yet. Use test collateral until the full lifecycle exists.

---

## 2. What happens in one `createMarket` call

```
 Admin                    Factory                OutcomeToken        New Market (clone)
  │                          │                        │                     │
  │ 1. approve(100 USDC)     │                        │                     │
  │ ───────────────────────▶ (on MockUSDC)           │                     │
  │                          │                        │                     │
  │ 2. createMarket(...)     │                        │                     │
  │ ───────────────────────▶ │                        │                     │
  │                          │ is caller admin?  ✔    │                     │
  │                          │ inputs valid?     ✔    │                     │
  │                          │ give it ID #1          │                     │
  │                          │ make a clone ─────────────────────────────▶ exists (empty)
  │                          │ 3. registerMarket(1) ─▶│ "slips for #1       │
  │                          │                        │  belong to this     │
  │                          │                        │  market"            │
  │                          │ 4. move 100 USDC  ───────────────────────▶   │ holds 100 USDC
  │                          │ 5. initialize() ──────────────────────────▶  │ saves settings
  │                          │                        │ ◀── 6. mint 100 YES  │ checks it got
  │                          │                        │      + 100 NO        │ the USDC
  │                          │ 7. announce "MarketCreated" (public log)      │
  │ ◀─────── (market #1 ready, priced 50 / 50) ──────────────────────────────│
```

The order matters. The market is registered *before* it mints, because the token contract only lets a registered market create slips. The USDC arrives *before* `initialize`, because the market checks the money is there before creating slips.

### The same flow as a story

1. The setup crew runs the deploy script. Now the front desk, the slip contract and the template market exist.
2. The admin gets play money, then tells the USDC contract "the front desk may take 100 from me".
3. The admin submits the question. The front desk checks they're allowed and that the inputs make sense.
4. The front desk builds market #1, tells the slip contract about it, moves the 100 USDC in, and tells the market to start.
5. The market saves its rules, confirms the money arrived, and creates 100 YES + 100 NO slips for its own pool.
6. The website reads the `MarketCreated` announcement and shows the new market at 50% / 50%.
7. When the close time passes, the market reports "Closed" on its own. Nobody has to press a button.

If any single step fails, the whole transaction is cancelled and nothing changes, so you never end up with a half-created market.

Sections 3–5 below go through each file line by line.

---

## 3. File by file

### 3.1 `MockUSDC.sol`: fake money

```solidity
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
```

- `is ERC20` means **inheritance**. We reuse OpenZeppelin's audited ERC-20 token code instead of writing our own. ERC-20 is the standard for fungible tokens like USDC: it provides `balanceOf`, `transfer`, `approve` and `transferFrom`.
- **Decimals**: blockchains have no decimal numbers, only whole numbers. With 6 decimals, `1 USDC = 1_000_000` units, which is why the code writes `10e6` for 10 USDC.
- `mint` lets *anyone* create tokens, which is fine for testing and a disaster on mainnet. On a real chain you'd use the real USDC address instead.

### 3.2 The interfaces (`src/interfaces/`)

An **interface** is a list of function names with no code, like a menu without the kitchen. It's what teammates and the frontend build against, which is why the team rule says to commit interfaces first (E0-4) and not change them without telling everyone.

Interfaces also hold the shared **types**, **events** and **errors**.

#### `IMarketFactory.sol`

**The input struct.** A `struct` groups fields together, so the frontend passes one object instead of 5 separate arguments:

```solidity
struct CreateParams {
    address arbitrator;              // who will resolve the market
    uint64  closeTime;               // when trading stops (unix seconds, UTC)
    uint16  initialYesProbabilityBps;// must be 5000 (= 50%) for now (Q3)
    string  spec;                    // the rules JSON; emitted, and hashed into specHash (Q5)
    uint256 initialLiquidity;        // how much USDC to seed the market with
}
```

There is no `collateral` field: every market uses the single token (USDC) fixed in the factory at deployment.

There is no fee or resolution deadline input. Every trade pays a flat 1% (`Market.FEE_BPS = 100`), accrued for the market creator and withdrawable after trading closes. The resolution deadline is `closeTime + 7 days` (`Market.RESOLUTION_WINDOW`); resolution and redemption behavior is not implemented yet.

`uint64` and `uint16` are smaller number types. They're big enough for timestamps and percentages, and the compiler can pack them together to save storage.

**The event:**

```solidity
event MarketCreated(uint256 indexed marketId, address indexed market, address indexed creator, ...);
```

An **event** is a log message stored on the blockchain. Contracts can't read events, but the frontend and indexer can. `indexed` fields are searchable, so the frontend can ask for "all markets created by address X". This is where the full `spec` text lives (Q5): a log costs about 8 gas per byte, storage about 20,000 gas per 32 bytes, and no contract ever reads the text.

**Custom errors:**

```solidity
error CloseTimeInPast(uint64 closeTime, uint256 currentTime);
error LiquidityTooLow(uint256 initialLiquidity, uint256 minLiquidity);
```

When a check fails, the transaction **reverts** (it's cancelled and all changes are undone) with one of these errors. Custom errors cost less gas than text messages and carry useful values, so the frontend can show something like "Close time must be after 14:30".

#### `IMarket.sol`

```solidity
enum State { Open, Closed, Proposed, Resolved, Cancelled }
enum Outcome { Yes, No }
```

An **enum** is a named list of options, stored as a number (Open = 0, Closed = 1, …). `State` is the market lifecycle from E1-3.

`InitParams` is the struct the factory passes to a new market. It's like `CreateParams`, plus things the factory decides itself: the market ID and the creator (`msg.sender`).

#### `IOutcomeToken.sol`

```solidity
interface IOutcomeToken is IERC1155 { ... }
```

Extends the standard ERC-1155 interface. **ERC-1155** is a multi-token standard: one contract holds many token types, each with an ID. The YES and NO tokens of every market are different IDs in the same contract.

### 3.3 `OutcomeTokenId.sol`: the token ID formula

```solidity
library OutcomeTokenId {
    function compute(uint256 marketId, IMarket.Outcome outcome) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(marketId, outcome)));
    }
}
```

- A **library** is reusable code with no storage of its own. The factory, the markets, the token contract and the tests all call the same function, so they can never disagree on IDs.
- This is Q2, hashed IDs. Market 1's YES token gets ID `keccak256(1, Yes)`, a huge random-looking number. Because it's a hash, no two (market, outcome) pairs ever collide.
- `pure` means it only does maths and doesn't read the blockchain, so it's free when called off-chain.
- The frontend must compute IDs the same way, e.g. with viem: `BigInt(keccak256(encodeAbiParameters([{type:'uint256'},{type:'uint8'}], [marketId, 0])))`, where 0 = Yes and 1 = No.

### 3.4 `OutcomeToken.sol`: the shared YES/NO token

```solidity
contract OutcomeToken is ERC1155Supply, IOutcomeToken {
    address public immutable factory;
    mapping(uint256 id => address market) public marketOf;
```

- `ERC1155Supply` is OpenZeppelin's ERC-1155 plus `totalSupply(id)`, which tells us how many YES tokens exist. We need that for the collateral rule.
- `immutable` is set once in the constructor and can never change. It's also cheaper to read than normal storage.
- A **mapping** is a dictionary/hash map: `marketOf[tokenId]` returns the market that owns that token ID.
- `public` makes Solidity create a getter function automatically, so anyone can call `marketOf(id)`.

**Registering a market:**

```solidity
function registerMarket(uint256 marketId, address market) external {
    if (msg.sender != factory) revert NotFactory(msg.sender);
    ...
    if (marketOf[yesId] != address(0)) revert MarketAlreadyRegistered(marketId);
    marketOf[yesId] = market;
    marketOf[noId] = market;
```

- `msg.sender` is the address that called this function. Only the factory may register markets.
- `address(0)` is the "empty" address. An unset mapping entry returns 0, so this check stops a token ID from being registered twice.

**Mint and burn:**

```solidity
modifier onlyMarketOf(uint256 id) {
    if (marketOf[id] != msg.sender) revert NotMarketForToken(msg.sender, id);
    _;
}
function mint(address to, uint256 id, uint256 amount) external onlyMarketOf(id) { _mint(to, id, amount, ""); }
```

- A **modifier** is a reusable check that runs before the function body. `_;` means "now run the function".
- This is the key security rule of the token: **Market #1 can only mint Market #1's tokens.** Even if Market #1 had a bug, it couldn't create tokens for Market #2. A test checks exactly this (`test_RevertWhen_MarketMintsAnotherMarketsToken`).
- `mintBatch` does the same check for every ID in the list, then mints them all in one call. Market creation uses it to mint YES and NO together, which is cheaper than two separate `mint` calls.
- `burn` isn't used yet. It's for redeeming tokens after resolution (E3-2), and it's in the interface now so the signature doesn't change later.

### 3.5 `Market.sol`: one prediction market

#### The clone idea (Q1)

Deploying a full contract for every market is expensive. Instead:

1. The factory deploys **one** real `Market` contract, the **implementation**, which holds the code.
2. Each new market is a **clone** (EIP-1167): a tiny contract of about 45 bytes that says "run the implementation's code, but use *my own* storage".

Each clone therefore has its own data and its own USDC balance, but shares the code.

**The catch:** clones don't run constructors, because constructor code only runs for the original. So settings are passed in an `initialize` function, and it **must only be callable once**. Otherwise an attacker could call it again and make themselves the arbitrator.

```solidity
contract Market is Initializable, ERC1155Holder, IMarket {
```

- `Initializable` (OpenZeppelin) provides the `initializer` modifier, which guarantees that `initialize` runs only once.
- `ERC1155Holder` lets this contract *receive* ERC-1155 tokens. The standard requires contracts to confirm "yes, I can hold these", so tokens don't get stuck in contracts that can't handle them.

#### The storage

```solidity
address public immutable factory;             // same for every clone (see below)
IOutcomeToken public immutable outcomeToken;  // same for every clone

uint256 public marketId;
...
bytes32 public specHash;      // Q5: just the fingerprint, 1 storage slot
uint256 public yesPool;       // AMM reserves
uint256 public noPool;
State internal _state;
```

None of these have setter functions. Once `initialize` sets them, nothing can change them (E1-2, parameters that can't change after creation).

**Why `factory` and `outcomeToken` are `immutable`:** immutables are baked into the implementation's *code*, not its storage. Clones run the implementation's code, so every clone automatically sees the same two values without paying about 20k gas each to store them. They're the same for every market anyway.

**Token IDs aren't stored either.** `yesTokenId()` and `noTokenId()` calculate `OutcomeTokenId.compute(marketId, ...)` each time they're called. Hashing costs less gas than storing the result and reading it back.

#### The constructor

```solidity
constructor(address factory_, IOutcomeToken outcomeToken_) {
    factory = factory_;
    outcomeToken = outcomeToken_;
    _disableInitializers();
}
```

This runs only once, for the **implementation** contract. It sets the two shared immutables and locks the implementation so nobody can call `initialize` on it directly. This prevents a classic attack where someone initializes the original and makes themselves its owner.

#### `initialize`

```solidity
function initialize(InitParams calldata p) external initializer {
    if (msg.sender != factory) revert NotFactory(msg.sender);
    marketId = p.marketId;
    ...
    _state = State.Open;

    uint256 balance = collateral.balanceOf(address(this));
    if (balance < p.initialLiquidity) revert CollateralNotReceived(p.initialLiquidity, balance);

    yesPool = p.initialLiquidity;
    noPool  = p.initialLiquidity;
    outcomeToken.mintBatch(address(this), [yesTokenId(), noTokenId()], [L, L]);  // simplified
}
```

- **Only the factory may initialize.** Without this check, anyone could call `initialize` on a brand-new clone before the factory does, in the brief window while the factory transfers the USDC, and make themselves the arbitrator. Today that would only make the creation transaction fail, but the check closes the gap completely.

- `calldata` means the input is read directly from the transaction data without copying, which is the cheapest way to pass arguments in.
- **The balance check** is a safety net. The market refuses to start unless it actually received the USDC, so it can never mint tokens backed by nothing. It uses `>=`, not `==`, on purpose. Clone addresses are predictable, so with `==` anyone could block market creation by sending 1 unit of USDC to the next market's address first. With `>=`, a stray donation only strands the donor's own money.
- **Seeding works like this.** The core rule of the design is *1 YES + 1 NO = 1 USDC*, because exactly one of them will be worth 1 USDC at the end. So 100 USDC in means 100 YES and 100 NO minted into the pool. The pool is equal, so the price is 50/50 (Q3).

#### `state()`: the derived "Closed" state

```solidity
function state() public view returns (State) {
    if (_state == State.Open && block.timestamp >= closeTime) return State.Closed;
    return _state;
}
```

- `block.timestamp` is the current block's time in unix seconds.
- `view` means it only reads data. Calling it from the frontend is free.
- Nobody needs to send a "close the market" transaction. As soon as the time passes, `state()` reports `Closed`; buy and sell functions require `state() == Open`.

#### Prices

```solidity
function priceYes() external view returns (uint256) {
    return (noPool * 1e18) / (yesPool + noPool);
}
```

- This is the AMM formula from the backlog: `P(YES) = NO_pool / (YES_pool + NO_pool)`.
- **Why `* 1e18`?** There are no decimals in Solidity, and `100 / 200` would give 0. Multiplying first gives `0.5 × 10^18 = 500000000000000000`, which the frontend divides by 10^18 to show "50%". This "18-decimal fixed point" convention is used across Ethereum.
- **Why the *NO* pool is on top:** when someone buys YES, YES tokens leave the pool, so the YES pool gets smaller relative to NO. YES becomes scarce and its price goes up.

### 3.6 `MarketFactory.sol`: the main contract

```solidity
contract MarketFactory is AccessControl, ReentrancyGuard, IMarketFactory {
    using SafeERC20 for IERC20;
```

- **AccessControl** (OpenZeppelin) is a role system. A role is just a name hashed into a `bytes32`. Admins can `grantRole` and `revokeRole`. Only `DEFAULT_ADMIN_ROLE` is used: it can create markets and manage admins. This is the Q6 "admin-only" decision, built so several teammates can hold the role.
- **ReentrancyGuard** provides the `nonReentrant` modifier, which blocks a function from being called again while it's still running. This defends against **reentrancy attacks**, where a malicious contract we call into calls back into us mid-function (the famous 2016 DAO hack). We call several external contracts during creation, so it's a cheap safety net. It also works safely in clones: it only blocks when its status is "entered", and a fresh clone's status starts at 0.
- **SafeERC20** exists because some real tokens don't follow the ERC-20 standard properly (for example, they return nothing instead of `true`). `safeTransferFrom` handles those cases and reverts if the transfer failed.

#### State

```solidity
address public immutable implementation;      // the Market "master copy"
IOutcomeToken public immutable outcomeToken;
IERC20  public immutable collateral;          // the one token used as money (USDC)
uint256 public immutable minLiquidity;        // Q7 limit, fixed at deploy

uint256 public marketCount;                   // also the last market ID
mapping(uint256 => address) public markets;   // id → market address
mapping(address => bool) public isMarket;     // is this address one of our markets?
```

#### Constructor

```solidity
constructor(address admin, address collateral_) {
    if (admin == address(0) || collateral_ == address(0)) revert InvalidConfig();
    collateral = IERC20(collateral_);
    ...
    OutcomeToken token = new OutcomeToken(address(this));
    outcomeToken = token;
    implementation = address(new Market(address(this), token));
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
}
```

- `new OutcomeToken(address(this))` deploys the shared token and tells it "I am your factory". `new Market(address(this), token)` deploys the implementation with its factory and outcome-token addresses. Deploying them here means only one deploy step and no risk of wiring the wrong addresses together.
- Zero minimums are rejected, because a market that closes instantly or has an empty pool makes no sense. This also lets `_validate` use simpler checks.
- The collateral token is fixed forever. Only USDC is supported, so there is no whitelist to manage; supporting another token means deploying a new factory.
- `DEFAULT_ADMIN_ROLE` can create markets and grant or revoke the role for other admins.
- The limits are constructor parameters (Q7), so the deploy script can use 10 minutes for a demo and longer values elsewhere.

#### `createMarket`

```solidity
function createMarket(CreateParams calldata p)
    external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
    returns (uint256 marketId, address market)
{
    _validate(p);
    marketId = ++marketCount;
    market = Clones.clone(implementation);
    markets[marketId] = market;
    isMarket[market] = true;
    outcomeToken.registerMarket(marketId, market);
    collateral.safeTransferFrom(msg.sender, market, p.initialLiquidity);
    IMarket(market).initialize(IMarket.InitParams({ ... creator: msg.sender, ... }));
    emit MarketCreated(marketId, market, msg.sender, ...);
}
```

This is the sequence from section 2. Some details:

- `++marketCount` adds one *before* using the value, so IDs start at **1**. ID 0 then always means "no market", which avoids confusing an empty lookup with a real market.
- **Order matters.** Registration happens before `initialize`, because `initialize` mints tokens and `OutcomeToken` only allows a *registered* market to mint. The USDC transfer happens before `initialize`, because `initialize` checks that the money arrived. Because `initialize` only accepts the factory as caller, nothing can sneak in between these steps.
- The USDC goes **directly from the admin to the market**. The factory never holds anyone's money, and each market's funds are isolated (the benefit of clones).
- `creator: msg.sender` is set by the factory, not taken from the input, so nobody can pretend to be someone else.

#### `_validate`: the input checks (E1-2)

```solidity
if (p.arbitrator == address(0)) revert ZeroArbitrator();
if (p.closeTime <= block.timestamp) revert CloseTimeInPast(...);
if (p.initialYesProbabilityBps != FIFTY_FIFTY_BPS) revert UnsupportedInitialProbability(...);
if (p.initialLiquidity < minLiquidity) revert LiquidityTooLow(...);
if (bytes(p.spec).length == 0) revert EmptySpec();
```

| Check | Why |
|---|---|
| Arbitrator ≠ 0 | Address 0 can never sign anything, so the market could never be resolved |
| Close time in the future | A market closing at or before now would start `Closed`, with its seed USDC locked and no way to trade. Only admins create markets, so there is no minimum duration beyond that |
| Probability = 50% | Only 50/50 is supported for now (Q3). The field exists so adding custom odds later doesn't change the interface |
| Liquidity ≥ minimum | Tiny pools make prices swing wildly. Since `minLiquidity` is never 0, this also rules out an empty pool, whose 0/0 price would crash `priceYes()` |
| Spec not empty | Every market must have committed rules (Q5). The factory hashes it itself, so the stored hash always matches the emitted text |

Arbitrator = creator is deliberately **allowed** (Q4).

There is no collateral check: the creator can't choose the token, so a fake or broken token can't be used as "money".

#### Known lint warnings

`forge build` shows a few lint warnings. They are expected and should be noted in `threat-model.md`:

- **block-timestamp**: validators can shift `block.timestamp` by a few seconds. That's irrelevant for close times measured in minutes or days.
- **reentrancy-events**: `MarketCreated` is emitted after external calls. That's safe here because `createMarket` is `nonReentrant` and only calls our own contracts plus the fixed collateral token.

---

## 4. The tests (`test/MarketFactory.t.sol`)

Foundry tests are written in Solidity. Every function starting with `test` is run, and if it reverts or an `assert` fails, the test fails.

**Setup (runs before every test):**

```solidity
function setUp() public {
    vm.warp(1_760_000_000);                   // set the blockchain clock to a fixed time
    usdc = new MockUSDC();
    factory = new MarketFactory(admin, address(usdc));
    usdc.mint(admin, 1_000_000e6);            // give the admin 1M fake USDC
    vm.prank(admin);
    usdc.approve(address(factory), type(uint256).max);  // admin allows the factory to take USDC
}
```

**Foundry "cheatcodes"** (`vm.*`) are special powers that only exist in tests:

| Cheatcode | What it does |
|---|---|
| `makeAddr("alice")` | Creates a labelled fake address |
| `vm.prank(alice)` | The **next** call comes from `alice` (it fakes `msg.sender`) |
| `vm.warp(t)` | Time travel: sets `block.timestamp` |
| `vm.expectRevert(err)` | The **next** call must fail with this exact error |
| `vm.expectEmit(...)` | The next call must emit this exact event |
| `bound(x, min, max)` | Squeezes a random fuzz value into a range |

> **Pitfall:** `prank` and `expectRevert` apply to the **next call**, and reading a value from a contract (e.g. `factory.DEFAULT_ADMIN_ROLE()`) *is* a call. Always read values into local variables first, then call `vm.prank` / `vm.expectRevert`, then make the call you're testing. This bug happened twice while writing these tests.

**Test groups:**

| Group | Examples | What it proves |
|---|---|---|
| Normal flow | `StoresParameters`, `EmitsMarketCreated`, `IdsIncrementFromOne`, `MovesCollateralAndSeedsPools`, `StartsAtFiftyFifty` | Creation works and everything is saved correctly |
| Access control | `CallerIsNotAdmin`, `GrantedAdminCanCreate`, `CollateralNotApproved` | Only admins can create; the creator must approve USDC first |
| Validation | One `RevertWhen_…` test per check, plus `AcceptsExactMinimums` | Every bad input is rejected; values exactly at the limit are accepted |
| State machine | `ClosedIsDerivedFromCloseTime` | 1 second before close → Open, at close → Closed |
| Clone and token safety | `MarketInitializedTwice`, `ImplementationInitialized`, `NonMarketMints`, `MarketMintsAnotherMarketsToken` | Nobody can hijack a market or mint tokens they shouldn't |
| Fuzz | `testFuzz_CreateMarket_FullyCollateralized` | See below |

**The fuzz test.** Foundry runs it **1000 times** with random close times, liquidity amounts and fees, and checks each time:

```solidity
assertGe(held, yesSupply);              // USDC in the market ≥ YES tokens that exist
assertGe(held, noSupply);               // USDC in the market ≥ NO tokens that exist
assertEq(m.priceYes() + m.priceNo(), 1e18);  // prices add up to 100%
```

This is the **collateral invariant** from the project plan: the market always holds enough money to pay every winner. Fuzzing tests it on random inputs instead of only the ones you thought of.

**The event test** needs to know the new market's address *before* it exists. The clone is created with the `CREATE` opcode, whose address is calculated from the creator's address and a counter (its "nonce"), so `vm.computeCreateAddress(factory, nonce)` predicts it.

---

## 5. The deploy script (`script/DeployMarketFactory.s.sol`)

```solidity
collateral = vm.envOr("COLLATERAL", address(0));
require(collateral != address(0) || _isTestChain(), "Set COLLATERAL: MockUSDC is test-chain only");

vm.startBroadcast();
address admin = vm.envOr("ADMIN", msg.sender);
require(admin != DEFAULT_SENDER, "No deployer wallet: ...");
if (collateral == address(0)) collateral = address(new MockUSDC());
factory = new MarketFactory(admin, collateral);
vm.stopBroadcast();
```

- `vm.envOr("X", default)` reads an environment variable or falls back to the default. This is how you change the Q7 limit without editing code.
- **MockUSDC guard:** anyone can mint MockUSDC, so the script only deploys it on Anvil and the Sepolia testnets (Base, Ethereum, Arbitrum). On any other chain you must pass `COLLATERAL`.
- **Admin guard:** if you forget to pass a wallet, Foundry uses a built-in default address that nobody controls. Making that the admin would lock the factory forever, so the script refuses.
- Everything between `startBroadcast` and `stopBroadcast` becomes **real transactions** when you run with `--broadcast`. Without that flag it's only a simulation.
- If you don't give it a `COLLATERAL` address, it deploys a fresh MockUSDC. On a testnet you'd normally do this once and reuse the address.

| Env var | Default | Meaning |
|---|---|---|
| `COLLATERAL` | deploy new MockUSDC (test chains only) | Existing collateral token address. Required on other chains |
| `ADMIN` | the deploying wallet | Who gets the admin role (can create markets) |

To try it locally:

```sh
anvil                                   # terminal 1: local blockchain
forge script script/DeployMarketFactory.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <one of anvil's printed keys>
```

---

## 6. Glossary

| Term | Meaning |
|---|---|
| `msg.sender` | Address that called the current function |
| `block.timestamp` | Current time (unix seconds) of the block |
| revert | Cancel the transaction and undo every change |
| gas | Fee for computation and storage; storage is the most expensive |
| `view` / `pure` | Read-only / maths-only functions, free when called off-chain |
| `external` / `public` / `internal` | Callable from outside only / from anywhere / only from this contract and its children |
| `immutable` / `constant` | Set once in the constructor / fixed at compile time |
| `calldata` / `memory` | Read-only transaction input / temporary working copy |
| approve + transferFrom | The two-step ERC-20 pattern: the owner allows a spender, and the spender pulls the tokens |
| bps | Basis points; 10,000 bps = 100% |
| clone (EIP-1167) | Tiny contract that reuses another contract's code with its own storage |
| implementation | The "master copy" contract that clones point to |

---

## 7. Verification results

Run on 2026-10-14 from `contracts/`, after applying the code-review fixes (section 8).

### Tests and coverage

`forge test`: **40 tests passing** (unit, access control, validation, clone/token safety, and a 1000-run fuzz test).

`forge coverage --no-match-coverage "(test|script|lib)/"`:

| File | Lines | Branches | Functions |
|---|---|---|---|
| `Market.sol` | 100% | 100% | 100% |
| `MarketFactory.sol` | 100% | 100% | 100% |
| `OutcomeToken.sol` | 100% | 100% | 100% |
| `OutcomeTokenId.sol` | 100% | n/a | 100% |
| `MockUSDC.sol` | 100% | n/a | 100% |

### Local deployment (Anvil)

Deployed with `DeployMarketFactory.s.sol`, then used `cast` against the live local node to:

- mint and approve mUSDC, then call `createMarket`: succeeded, **584,393 gas** (676,226 before the review fixes)
- read back: `marketCount = 1`, `state = Open`, `priceYes = 0.5e18`, `specHash` matches, market holds 100 mUSDC, `factory()` returns the factory
- advance time past `closeTime`: `state = Closed`
- call `createMarket` from a non-admin: reverted with `AccessControlUnauthorizedAccount(nonAdmin, MARKET_CREATOR_ROLE)`
- deploy-script guards: no wallet → refused; `MAX_FEE_BPS=70000` → `SafeCastOverflowedUintDowncast`; MockUSDC on chain ID 1 → refused

### Slither (0.11.6)

`slither . --filter-paths "lib/|test/|script/"`: **no high or medium findings.** 7 low/informational results, all triaged:

| Detector | Location | Verdict |
|---|---|---|
| `missing-zero-check` (×2) | `Market` and `OutcomeToken` constructors | Accepted: both are only deployed by the factory's constructor with `address(this)` |
| `timestamp` (×2) | `Market.state()`, `MarketFactory._validate` | Intended: a few seconds of validator drift is irrelevant for close times in minutes or days |
| `events-maths` | `Market.initialize` | Accepted: the factory emits `MarketCreated` with every parameter in the same transaction |
| `naming-convention` | `MARKET_CREATOR_ROLE()` | False positive: standard OpenZeppelin role-constant style |
| `unimplemented-functions` | `OutcomeToken.totalSupply(uint256)` | False positive: implemented with `override(ERC1155Supply, IOutcomeToken)`; Slither is confused by the `totalSupply` overloads |

### Not covered yet (needs later epics)

- End-to-end lifecycle test through resolution and redemption still needs those settlement functions.
- Stateful `invariant_` tests become meaningful once trading exists.
- Reentrancy tests with a malicious token matter once trading and redemption move funds to users.

---

## 8. Code review fixes

A code review found 9 issues, none exploitable by an outsider to take funds.

**Fixed:**

| Issue | Fix |
|---|---|
| Anyone could call `initialize` on a new clone before the factory did | `initialize` only accepts the factory, whose address is an immutable set in the implementation's constructor |
| `factory`, `outcomeToken` and both token IDs were written to every clone's storage | `factory`/`outcomeToken` are immutables; token IDs are computed on read |
| YES and NO were minted with two separate calls | One `mintBatch` call |
| Deploy-script settings could silently wrap around (`uint16(70000)` = 4464) | `SafeCast` |
| Deploy script could deploy free-mint MockUSDC on any chain | Only on Anvil and Sepolia testnets |
| Deploy script could make Foundry's default sender the admin | Refuses to deploy without a real wallet |
| Validation had redundant checks for zero minimums | Constructor rejects zero minimums; duplicate checks removed |

Together these cut market creation gas by about 92k (−13.6%).

**Not changed, by decision:**

| Issue | Why |
|---|---|
| Seed liquidity has no withdrawal path yet | Resolution, redemption, and liquidity withdrawal are not implemented yet; accrued trading fees can be withdrawn to the creator after close |
| Balance check is `>=`, so tokens sent to the address early are counted | Using `==` would let anyone block creation by sending 1 unit to the predictable next market address. With `>=`, a stray donation only strands the donor's own money |
| `OutcomeToken` stores the owner for both the YES and NO IDs (2 writes) | Removing it saves about 22k gas but needs an awkward mint signature, because a hashed token ID can't be turned back into a market ID |
