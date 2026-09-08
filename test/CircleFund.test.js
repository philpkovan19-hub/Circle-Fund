const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("CircleFund", function () {
  let cf, owner, a, b, c, d;
  const AMT = ethers.parseEther("1");
  const ROUND = 3600; // 1 hour

  beforeEach(async () => {
    [owner, a, b, c, d] = await ethers.getSigners();
    const F = await ethers.getContractFactory("CircleFund");
    cf = await F.deploy();
    await cf.waitForDeployment();
  });

  async function makeCircle(size = 3) {
    await cf.connect(a).createCircle(size, AMT, ROUND);
    return 0n;
  }

  it("creates a circle with creator as member 0", async () => {
    await makeCircle(3);
    const members = await cf.getMembers(0);
    expect(members.length).to.equal(1);
    expect(members[0]).to.equal(a.address);
    expect(await cf.circleCount()).to.equal(1n);
  });

  it("rejects size outside 2-20", async () => {
    await expect(cf.createCircle(1, AMT, ROUND)).to.be.revertedWith("size 2-20");
    await expect(cf.createCircle(21, AMT, ROUND)).to.be.revertedWith("size 2-20");
  });

  it("lets members join and rejects duplicates and overflow", async () => {
    await makeCircle(3);
    await cf.connect(b).joinCircle(0);
    await expect(cf.connect(b).joinCircle(0)).to.be.revertedWith("already joined");
    await cf.connect(c).joinCircle(0);
    await expect(cf.connect(d).joinCircle(0)).to.be.revertedWith("full");
  });

  it("startCircle requires creator and a full roster", async () => {
    await makeCircle(3);
    await cf.connect(b).joinCircle(0);
    await expect(cf.connect(a).startCircle(0)).to.be.revertedWith("not full");
    await cf.connect(c).joinCircle(0);
    await expect(cf.connect(b).startCircle(0)).to.be.revertedWith("not creator");
    await cf.connect(a).startCircle(0);
    const info = await cf.getCircle(0);
    expect(info[7]).to.equal(1); // Active
  });

  it("contribute requires exact amount and only once per round", async () => {
    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    await cf.connect(a).startCircle(0);
    await expect(cf.connect(a).contributeRound(0, { value: AMT + 1n })).to.be.revertedWith("wrong amount");
    await cf.connect(a).contributeRound(0, { value: AMT });
    await expect(cf.connect(a).contributeRound(0, { value: AMT })).to.be.revertedWith("already contributed");
  });

  it("only the member whose turn it is can claim, and pot is (fee-adjusted) sum of contributions", async () => {
    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    await cf.connect(a).startCircle(0);
    await cf.connect(a).contributeRound(0, { value: AMT });
    await cf.connect(b).contributeRound(0, { value: AMT });
    // round 0, a is turn
    await expect(cf.connect(b).claimPot(0)).to.be.revertedWith("not your turn");
    const balBefore = await ethers.provider.getBalance(a.address);
    const tx = await cf.connect(a).claimPot(0);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const balAfter = await ethers.provider.getBalance(a.address);
    const pot = AMT * 2n;
    const fee = (pot * 100n) / 10000n;
    const payout = pot - fee;
    expect(balAfter - balBefore + gas).to.equal(payout);
    expect(await cf.accumulatedFees()).to.equal(fee);
  });

  it("advances rounds and completes the circle after final round", async () => {
    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    await cf.connect(a).startCircle(0);

    // round 0 -> a claims
    await cf.connect(a).contributeRound(0, { value: AMT });
    await cf.connect(b).contributeRound(0, { value: AMT });
    await cf.connect(a).claimPot(0);
    let info = await cf.getCircle(0);
    expect(info[5]).to.equal(1); // currentRound
    expect(info[7]).to.equal(1); // still Active

    // round 1 -> b claims -> completes
    await cf.connect(a).contributeRound(0, { value: AMT });
    await cf.connect(b).contributeRound(0, { value: AMT });
    await cf.connect(b).claimPot(0);
    info = await cf.getCircle(0);
    expect(info[7]).to.equal(2); // Completed
  });

  it("whoseTurnIsIt tracks the current round member", async () => {
    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    await cf.connect(a).startCircle(0);
    expect(await cf.whoseTurnIsIt(0)).to.equal(a.address);
    await cf.connect(a).contributeRound(0, { value: AMT });
    await cf.connect(b).contributeRound(0, { value: AMT });
    await cf.connect(a).claimPot(0);
    expect(await cf.whoseTurnIsIt(0)).to.equal(b.address);
  });

  it("claim allowed after round window even with missing contributors (defaulter path)", async () => {
    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    await cf.connect(a).startCircle(0);
    await cf.connect(a).contributeRound(0, { value: AMT });
    // b never contributes; before window - blocked
    await expect(cf.connect(a).claimPot(0)).to.be.revertedWith("round not ready");
    await time.increase(ROUND + 1);
    await cf.connect(a).claimPot(0); // succeeds with just a's contribution
  });

  it("hasContributedThisRound and getContributionsThisRound reflect state", async () => {
    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    await cf.connect(a).startCircle(0);
    expect(await cf.hasContributedThisRound(0, a.address)).to.equal(false);
    await cf.connect(a).contributeRound(0, { value: AMT });
    expect(await cf.hasContributedThisRound(0, a.address)).to.equal(true);
    expect(await cf.getContributionsThisRound(0)).to.equal(AMT);
  });

  it("getCirclesByMember lists joined circle ids", async () => {
    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    const ids = await cf.getCirclesByMember(b.address);
    expect(ids.length).to.equal(1);
    expect(ids[0]).to.equal(0n);
  });

  it("admin can set fee (bounded) and withdraw fees", async () => {
    await expect(cf.setPlatformFeeBps(2000)).to.be.revertedWith("fee too high");
    await cf.setPlatformFeeBps(200);
    expect(await cf.platformFeeBps()).to.equal(200);

    await makeCircle(2);
    await cf.connect(b).joinCircle(0);
    await cf.connect(a).startCircle(0);
    await cf.connect(a).contributeRound(0, { value: AMT });
    await cf.connect(b).contributeRound(0, { value: AMT });
    await cf.connect(a).claimPot(0);
    const fees = await cf.accumulatedFees();
    expect(fees).to.be.gt(0n);
    await expect(cf.withdrawFees(owner.address)).to.emit(cf, "FeesWithdrawn");
    expect(await cf.accumulatedFees()).to.equal(0n);
  });

  it("pause blocks state-changing calls", async () => {
    await cf.pause();
    await expect(cf.createCircle(2, AMT, ROUND)).to.be.revertedWithCustomError(cf, "EnforcedPause");
    await cf.unpause();
    await cf.createCircle(2, AMT, ROUND);
  });
});
