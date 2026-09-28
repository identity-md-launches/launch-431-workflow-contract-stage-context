// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";
import {Banners} from "../src/Banners.sol";

/// @dev Emulates the launch: the factory deploys the token, then Guilds and Realm in manifest
/// order with the production constructor arguments. Checks what the project floor checks, on
/// every contract including the three Realm creates, plus the EIP-3860 init code cap the floor's
/// CREATE2 is subject to on Sepolia.
contract LaunchTest is Test {
    uint256 internal constant EPOCH_LENGTH = 1 hours;
    uint256 internal constant SEASON_LENGTH = 7 days;
    uint256 internal constant TROOP_PRICE = 1e18;
    uint256 internal constant FEE_BPS = 1000;

    address internal factory = makeAddr("factory");
    LaunchToken internal token;
    Guilds internal guilds;
    Realm internal realm;

    function setUp() public {
        vm.startPrank(factory);
        token = new LaunchToken();
        guilds = new Guilds();
        realm = new Realm(address(token), address(guilds), EPOCH_LENGTH, SEASON_LENGTH, TROOP_PRICE, FEE_BPS);
        vm.stopPrank();
    }

    function test_constructorsDoNotTouchTheSupply() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(factory), 10 ** 27);
        assertEq(token.balanceOf(address(realm)), 0);
        assertEq(token.balanceOf(address(realm.season())), 0);
    }

    function test_productionParameters() public view {
        assertEq(realm.epochLength(), 1 hours);
        assertEq(realm.seasonLength(), 7 days);
        assertEq(realm.epochsPerSeason(), 168);
        assertEq(realm.season().epochsPerSeason(), 168);
        assertEq(realm.troopPrice(), 1e18);
        assertEq(realm.feeBps(), 1000);
        assertEq(realm.MAP_SIZE(), 12);
        assertEq(realm.TILE_COUNT(), 144);
        assertEq(address(realm.diplomacy().realm()), address(realm));
        assertEq(address(realm.season().realm()), address(realm));
        assertEq(realm.season().banners().minter(), address(realm.season()));
    }

    function test_nothingDependsOnAnOwner() public view {
        // No contract stores the factory or any privileged address.
        assertEq(guilds.guildCount(), 0);
        assertEq(realm.settledEpoch(), 0);
        (bool ok,) = address(realm).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(guilds).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    function test_runtimeSizesAndOpcodes() public view {
        address[6] memory contracts = [
            address(token),
            address(guilds),
            address(realm),
            address(realm.diplomacy()),
            address(realm.season()),
            address(realm.season().banners())
        ];
        for (uint256 i; i < contracts.length; ++i) {
            bytes memory code = contracts[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }

    function test_initCodeUnderEip3860Limit() public pure {
        bytes memory realmInit = abi.encodePacked(
            type(Realm).creationCode,
            abi.encode(address(1), address(2), EPOCH_LENGTH, SEASON_LENGTH, TROOP_PRICE, FEE_BPS)
        );
        assertLt(realmInit.length, 49_152, "Realm init code exceeds EIP-3860");
        assertLt(type(Guilds).creationCode.length, 49_152);
        assertLt(type(LaunchToken).creationCode.length, 49_152);
    }

    function test_deploysThroughCreate2LikeTheFactory() public {
        bytes memory init = abi.encodePacked(
            type(Realm).creationCode,
            abi.encode(address(token), address(guilds), EPOCH_LENGTH, SEASON_LENGTH, TROOP_PRICE, FEE_BPS)
        );
        address deployed;
        vm.prank(factory);
        assembly ("memory-safe") {
            deployed := create2(0, add(init, 32), mload(init), 0x1234)
        }
        assertTrue(deployed != address(0));
        assertGt(deployed.code.length, 0);
        assertEq(address(Realm(deployed).guilds()), address(guilds));
        assertEq(token.balanceOf(factory), 10 ** 27);
    }
}
