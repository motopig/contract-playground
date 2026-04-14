// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IdentityRegistry} from "../../src/8004/IdentityRegistry.sol";
import {IIdentityRegistry} from "../../src/8004/interfaces/IIdentityRegistry.sol";

contract IdentityTest is Test {
    IdentityRegistry public reg;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    string constant DATA_URI =
        'data:application/json,{"name":"AgentAlpha","description":"Demo AI agent","version":"1.0"}';

    function setUp() public {
        reg = new IdentityRegistry();
    }

    // ───────── Registration ─────────

    function test_register_basic() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);

        assertEq(id, 1);
        assertEq(reg.ownerOf(id), alice);
        assertEq(reg.agentURI(id), DATA_URI);
        assertEq(reg.totalAgents(), 1);
    }

    function test_register_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IIdentityRegistry.Registered(1, alice, DATA_URI);
        reg.register(DATA_URI);
    }

    function test_register_incrementsId() public {
        vm.prank(alice);
        uint256 id1 = reg.register(DATA_URI);
        vm.prank(bob);
        uint256 id2 = reg.register("data:application/json,{}");

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(reg.totalAgents(), 2);
    }

    // ───────── URI Update ─────────

    function test_setAgentURI() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);

        string memory newURI = "data:application/json,{\"v\":2}";
        vm.prank(alice);
        reg.setAgentURI(id, newURI);

        assertEq(reg.agentURI(id), newURI);
    }

    function test_setAgentURI_revertNotOwner() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);

        vm.prank(bob);
        vm.expectRevert("IdentityRegistry: not owner");
        reg.setAgentURI(id, "x");
    }

    // ───────── Metadata ─────────

    function test_metadata_setAndGet() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);

        vm.prank(alice);
        reg.setMetadata(id, "capability", "text-generation");

        assertEq(reg.getMetadata(id, "capability"), "text-generation");
    }

    function test_metadata_revertNotOwner() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);

        vm.prank(bob);
        vm.expectRevert("IdentityRegistry: not owner");
        reg.setMetadata(id, "k", "v");
    }

    // ───────── Wallet ─────────

    function test_wallet_setAndGet() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);

        address wallet = makeAddr("wallet");

        vm.prank(alice);
        reg.setAgentWallet(id, wallet);
        assertEq(reg.getAgentWallet(id), wallet);
    }

    function test_wallet_unset() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);
        address wallet = makeAddr("wallet");

        vm.prank(alice);
        reg.setAgentWallet(id, wallet);

        vm.prank(alice);
        reg.unsetAgentWallet(id, wallet);
        assertEq(reg.getAgentWallet(id), address(0));
    }

    function test_wallet_revertZeroAddress() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);

        vm.prank(alice);
        vm.expectRevert("IdentityRegistry: zero address");
        reg.setAgentWallet(id, address(0));
    }

    function test_wallet_revertMismatchOnUnset() public {
        vm.prank(alice);
        uint256 id = reg.register(DATA_URI);
        address wallet = makeAddr("wallet");
        address wrong = makeAddr("wrong");

        vm.prank(alice);
        reg.setAgentWallet(id, wallet);

        vm.prank(alice);
        vm.expectRevert("IdentityRegistry: wallet mismatch");
        reg.unsetAgentWallet(id, wrong);
    }

    // ───────── Edge: non-existent agent ─────────

    function test_revert_nonExistentAgent() public {
        vm.expectRevert("IdentityRegistry: agent does not exist");
        reg.ownerOf(999);
    }
}
