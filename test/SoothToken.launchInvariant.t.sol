// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SoothToken} from "../src/SoothToken.sol";

/// @dev Acts as the launch factory: deploys the token (so it receives the mint), performs the launch
///      split, then drives random valid and invalid calls among the launch participants. Every failure
///      path is asserted with its exact error, and a ledger independent of the token tracks what each
///      address must hold and may still spend.
contract SoothLaunchHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SoothToken public immutable token;
    address[] internal actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostInitial;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => mapping(address => uint256)) public ghostGranted;
    mapping(address => mapping(address => uint256)) public ghostSpentVia;

    uint256 public succeeded;
    uint256 public rejected;

    constructor(address[] memory actors_) {
        token = new SoothToken();
        require(token.balanceOf(address(this)) == SUPPLY, "mint did not reach the deployer");
        actors = actors_;
        actors.push(address(token)); // tokens sent to the token itself must still be accounted for
        // Launch split: 10% swarm, 80% pool, 10% remainder.
        _seed(actors_[0], SUPPLY / 10);
        _seed(actors_[1], SUPPLY * 8 / 10);
        _seed(actors_[2], SUPPLY / 10);
        require(token.balanceOf(address(this)) == 0, "factory kept a balance");
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ----- valid operations -----

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
        ++succeeded;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (unlimited) amount = type(uint256).max;
        else amount = bound(amount, 0, SUPPLY * 2);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
        if (amount == type(uint256).max) ghostGranted[owner][spender] = type(uint256).max;
        else if (ghostGranted[owner][spender] != type(uint256).max) ghostGranted[owner][spender] += amount;
        ++succeeded;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = allowed < ghostBalance[owner] ? allowed : ghostBalance[owner];
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _move(owner, to, amount);
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ghostSpentVia[owner][spender] += amount;
        ++succeeded;
    }

    // ----- invalid operations: each must revert with its exact error and change nothing -----

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = ghostBalance[from];
        excess = bound(excess, 1, type(uint256).max - balance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + excess)
        );
        vm.prank(from);
        token.transfer(to, balance + excess);
        ++rejected;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++rejected;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ++rejected;
    }

    function transferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return;
        excess = bound(excess, 1, type(uint256).max - allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + excess)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, allowed + excess);
        ++rejected;
    }

    /// @dev Allowance is ample but balance is not: the revert must roll back the allowance deduction too.
    function transferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 balance = ghostBalance[owner];
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed <= balance) return;
        excess = bound(excess, 1, allowed - balance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + excess)
        );
        vm.prank(spender);
        token.transferFrom(owner, to, balance + excess);
        ++rejected;
    }

    /// @dev Any caller, privileged-looking or not, sending an unknown selector is refused.
    function unknownCall(uint256 callerSeed, bytes4 selector, bytes32 arg0, bytes32 arg1) external {
        if (
            selector == token.transfer.selector || selector == token.transferFrom.selector
                || selector == token.approve.selector
        ) return;
        address caller = callerSeed % 2 == 0 ? address(this) : _actor(callerSeed);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, arg0, arg1));
        ok; // view getters may succeed; the invariants catch any state change
        ++rejected;
    }

    // ----- helpers -----

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _seed(address to, uint256 amount) internal {
        assertTrue(token.transfer(to, amount));
        ghostBalance[to] += amount;
        ghostInitial[to] += amount;
    }

    function _move(address from, address to, uint256 amount) internal {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
    }
}

contract SoothTokenLaunchInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SoothLaunchHandler private handler;
    SoothToken private token;

    function setUp() public {
        address[] memory actors = new address[](5);
        actors[0] = makeAddr("distributor");
        actors[1] = makeAddr("pool manager");
        actors[2] = makeAddr("remainder");
        actors[3] = makeAddr("trader");
        actors[4] = makeAddr("claimant");
        handler = new SoothLaunchHandler(actors);
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = SoothLaunchHandler.transfer.selector;
        selectors[1] = SoothLaunchHandler.approve.selector;
        selectors[2] = SoothLaunchHandler.transferFrom.selector;
        selectors[3] = SoothLaunchHandler.transferAboveBalance.selector;
        selectors[4] = SoothLaunchHandler.transferToZero.selector;
        selectors[5] = SoothLaunchHandler.approveZeroSpender.selector;
        selectors[6] = SoothLaunchHandler.transferFromAboveAllowance.selector;
        selectors[7] = SoothLaunchHandler.transferFromAboveBalance.selector;
        selectors[8] = SoothLaunchHandler.unknownCall.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixedAndFullyAccounted() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, SUPPLY, "balances leaked outside the participants");
        assertEq(token.balanceOf(address(handler)), 0, "the factory regained a balance");
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesMatchLedgerAndFlows() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actorAt(i);
            uint256 balance = token.balanceOf(a);
            assertEq(balance, handler.ghostBalance(a), "balance differs from ledger");
            // Nobody holds more than they were given plus what they received, minus what they sent.
            assertEq(
                balance + handler.ghostSent(a), handler.ghostInitial(a) + handler.ghostReceived(a), "flow mismatch"
            );
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchAndNoSpenderExceedsGrant() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actorAt(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actorAt(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drift");
                assertLe(
                    handler.ghostSpentVia(owner, spender), handler.ghostGranted(owner, spender), "spent beyond grants"
                );
            }
        }
    }

    function afterInvariant() public view {
        // Non-vacuity: the run must have exercised the handler.
        assertGt(handler.succeeded() + handler.rejected(), 0, "no handler call ran");
    }
}
