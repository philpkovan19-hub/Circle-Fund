# CircleFund

Rotating savings & credit associations (ROSCA / digital chit fund / _tanda_ / _susu_ / _committee_) on **BOT Chain**.

A small group of people (2–20) agrees to contribute a fixed amount every round. Each round, one member takes the whole pot. When everyone has taken a turn, the circle is complete — no interest, no lenders, just neighbours saving together on-chain.

## Mechanics

1. **Form a circle** — creator picks size, per-round contribution and round duration.
2. **Fill the seats** — anyone can join until the roster is full.
3. **Start** — creator locks it in; round 0 begins.
4. **Contribute each round** — every member pays `amountPerRound`.
5. **Take your turn** — the member whose seat matches the current round claims the pot (minus a 1% platform fee).
6. Repeat until every member has claimed once. Circle status becomes `Completed`.

If a round window elapses with missing contributors, the current beneficiary can still claim what was contributed. Anyone can `advanceRound` a stuck circle after the window ends.

## Networks

| Network | Chain ID | RPC | Explorer |
|---|---|---|---|
| Testnet | 968 (0x3C8) | https://rpc.bohr.life | https://scan.bohr.life |
| Mainnet | 677 (0x2A5) | https://rpc.botchain.ai | https://scan.botchain.ai |

Native token: **BOT** (18 decimals).

## Quickstart

```bash
npm install
npx hardhat compile
npx hardhat test

cp .env.example .env    # add your PRIVATE_KEY
npm run deploy:testnet
```

Then update `CONTRACT_ADDRESS` in `frontend/index.html` and open it in your browser (or `vercel deploy`).

## Run a full round (locally)

```bash
npx hardhat console --network hardhat
> const F = await ethers.getContractFactory("CircleFund")
> const cf = await F.deploy(); await cf.waitForDeployment()
> const [a,b] = await ethers.getSigners()
> await cf.createCircle(2, ethers.parseEther("1"), 3600)
> await cf.connect(b).joinCircle(0)
> await cf.startCircle(0)
> await cf.contributeRound(0, { value: ethers.parseEther("1") })
> await cf.connect(b).contributeRound(0, { value: ethers.parseEther("1") })
> await cf.claimPot(0)   // round 0 -> creator
```

## License

MIT
