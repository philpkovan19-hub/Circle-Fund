// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title CircleFund - Rotating savings & credit associations (ROSCA / digital chit fund) on BOT Chain
contract CircleFund is Ownable, ReentrancyGuard, Pausable {
    enum Status { Recruiting, Active, Completed, Cancelled }

    struct Circle {
        address creator;
        uint8 size;
        uint256 amountPerRound;
        uint256 roundSecs;
        uint256 startTime;
        uint8 currentRound;
        uint8 memberCount;
        Status status;
        uint256 currentRoundContributions;
        uint256 currentRoundStart;
        bool potClaimedThisRound;
    }

    uint256 public circleCount;
    uint16 public platformFeeBps = 100; // 1%
    uint256 public accumulatedFees;

    mapping(uint256 => Circle) private circles;
    mapping(uint256 => address[]) private circleMembers;
    mapping(uint256 => mapping(address => bool)) public isMember;
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) public contributedInRound;
    mapping(uint256 => mapping(uint8 => uint256)) public roundContributionCount;
    mapping(address => uint256[]) private memberCircles;

    event CircleCreated(uint256 indexed circleId, address indexed creator, uint8 size, uint256 amountPerRound, uint256 roundSecs);
    event MemberJoined(uint256 indexed circleId, address indexed member, uint8 seat);
    event CircleStarted(uint256 indexed circleId, uint256 startTime);
    event Contributed(uint256 indexed circleId, uint8 indexed round, address indexed member, uint256 amount);
    event PotClaimed(uint256 indexed circleId, uint8 indexed round, address indexed recipient, uint256 amount, uint256 fee);
    event RoundAdvanced(uint256 indexed circleId, uint8 newRound);
    event CircleCompleted(uint256 indexed circleId);
    event PlatformFeeUpdated(uint16 newFeeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // -------------------- Circle lifecycle --------------------

    function createCircle(uint8 size, uint256 amountPerRound, uint256 roundSecs)
        external
        whenNotPaused
        returns (uint256 circleId)
    {
        require(size >= 2 && size <= 20, "size 2-20");
        require(amountPerRound > 0, "amount>0");
        require(roundSecs >= 60, "round too short");

        circleId = circleCount++;
        Circle storage c = circles[circleId];
        c.creator = msg.sender;
        c.size = size;
        c.amountPerRound = amountPerRound;
        c.roundSecs = roundSecs;
        c.status = Status.Recruiting;

        _addMember(circleId, msg.sender);

        emit CircleCreated(circleId, msg.sender, size, amountPerRound, roundSecs);
    }

    function joinCircle(uint256 circleId) external whenNotPaused {
        Circle storage c = circles[circleId];
        require(c.status == Status.Recruiting, "not recruiting");
        require(c.memberCount < c.size, "full");
        require(!isMember[circleId][msg.sender], "already joined");

        _addMember(circleId, msg.sender);
        emit MemberJoined(circleId, msg.sender, c.memberCount - 1);
    }

    function _addMember(uint256 circleId, address who) internal {
        Circle storage c = circles[circleId];
        circleMembers[circleId].push(who);
        isMember[circleId][who] = true;
        memberCircles[who].push(circleId);
        c.memberCount++;
    }

    function startCircle(uint256 circleId) external whenNotPaused {
        Circle storage c = circles[circleId];
        require(msg.sender == c.creator, "not creator");
        require(c.status == Status.Recruiting, "not recruiting");
        require(c.memberCount == c.size, "not full");

        c.status = Status.Active;
        c.startTime = block.timestamp;
        c.currentRound = 0;
        c.currentRoundStart = block.timestamp;
        emit CircleStarted(circleId, block.timestamp);
    }

    // -------------------- Contribute / claim --------------------

    function contributeRound(uint256 circleId) external payable whenNotPaused nonReentrant {
        Circle storage c = circles[circleId];
        require(c.status == Status.Active, "not active");
        require(isMember[circleId][msg.sender], "not member");
        require(msg.value == c.amountPerRound, "wrong amount");
        require(!contributedInRound[circleId][c.currentRound][msg.sender], "already contributed");

        contributedInRound[circleId][c.currentRound][msg.sender] = true;
        roundContributionCount[circleId][c.currentRound] += 1;
        c.currentRoundContributions += msg.value;

        emit Contributed(circleId, c.currentRound, msg.sender, msg.value);
    }

    function claimPot(uint256 circleId) external whenNotPaused nonReentrant {
        Circle storage c = circles[circleId];
        require(c.status == Status.Active, "not active");
        address turn = circleMembers[circleId][c.currentRound];
        require(msg.sender == turn, "not your turn");
        require(!c.potClaimedThisRound, "already claimed");
        require(
            roundContributionCount[circleId][c.currentRound] == c.memberCount ||
                block.timestamp >= c.currentRoundStart + c.roundSecs,
            "round not ready"
        );

        uint256 pot = c.currentRoundContributions;
        uint256 fee = (pot * platformFeeBps) / 10_000;
        uint256 payout = pot - fee;
        accumulatedFees += fee;
        c.potClaimedThisRound = true;

        (bool ok, ) = payable(turn).call{value: payout}("");
        require(ok, "transfer failed");
        emit PotClaimed(circleId, c.currentRound, turn, payout, fee);

        _advanceRound(circleId);
    }

    /// @notice Anyone can poke a round to advance it if the window has elapsed and pot has been claimed or nobody contributed.
    function advanceRound(uint256 circleId) external whenNotPaused {
        Circle storage c = circles[circleId];
        require(c.status == Status.Active, "not active");
        require(block.timestamp >= c.currentRoundStart + c.roundSecs, "window not over");
        // If pot not claimed (no one contributed / claimant skipped), forfeit unclaimed pot to fees and move on.
        if (!c.potClaimedThisRound && c.currentRoundContributions > 0) {
            accumulatedFees += c.currentRoundContributions;
        }
        _advanceRound(circleId);
    }

    function _advanceRound(uint256 circleId) internal {
        Circle storage c = circles[circleId];
        uint8 next = c.currentRound + 1;
        c.currentRoundContributions = 0;
        c.potClaimedThisRound = false;
        if (next >= c.size) {
            c.status = Status.Completed;
            emit CircleCompleted(circleId);
        } else {
            c.currentRound = next;
            c.currentRoundStart = block.timestamp;
            emit RoundAdvanced(circleId, next);
        }
    }

    // -------------------- Views --------------------

    function getCircle(uint256 circleId)
        external
        view
        returns (
            address creator,
            uint8 size,
            uint256 amountPerRound,
            uint256 roundSecs,
            uint256 startTime,
            uint8 currentRound,
            uint8 memberCount,
            uint8 status
        )
    {
        Circle storage c = circles[circleId];
        return (
            c.creator,
            c.size,
            c.amountPerRound,
            c.roundSecs,
            c.startTime,
            c.currentRound,
            c.memberCount,
            uint8(c.status)
        );
    }

    function getMembers(uint256 circleId) external view returns (address[] memory) {
        return circleMembers[circleId];
    }

    function whoseTurnIsIt(uint256 circleId) external view returns (address) {
        Circle storage c = circles[circleId];
        if (c.memberCount == 0 || c.currentRound >= c.memberCount) return address(0);
        return circleMembers[circleId][c.currentRound];
    }

    function hasContributedThisRound(uint256 circleId, address member) external view returns (bool) {
        return contributedInRound[circleId][circles[circleId].currentRound][member];
    }

    function getContributionsThisRound(uint256 circleId) external view returns (uint256) {
        return circles[circleId].currentRoundContributions;
    }

    function getCirclesByMember(address who) external view returns (uint256[] memory) {
        return memberCircles[who];
    }

    // -------------------- Admin --------------------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setPlatformFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= 1000, "fee too high"); // max 10%
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newFeeBps);
    }

    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        uint256 amount = accumulatedFees;
        accumulatedFees = 0;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
        emit FeesWithdrawn(to, amount);
    }
}
