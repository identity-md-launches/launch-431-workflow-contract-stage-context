// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Banners
/// @notice Trophy ERC-721 of the Pacts game. Only the Season contract, which creates this
/// contract in its constructor, can mint. Victory banners go to each member of a top-three guild,
/// honour banners to a guild that finished a season with pacts and without breaking one.
contract Banners is ERC721 {
    uint8 public constant KIND_VICTORY = 1;
    uint8 public constant KIND_HONOUR = 2;

    struct Banner {
        uint64 season;
        uint64 guild;
        uint8 kind;
        uint8 rank;
    }

    address public immutable minter;
    uint256 public totalMinted;
    mapping(uint256 tokenId => Banner) private _banners;

    event BannerMinted(
        uint256 indexed tokenId, address indexed to, uint256 indexed season, uint256 guild, uint8 kind, uint8 rank
    );

    error NotMinter();
    error InvalidKind();

    constructor() ERC721("Pacts Banner", "BANNER") {
        minter = msg.sender;
    }

    /// @notice Mint a banner. Callable only by Season.
    function mint(address to, uint256 season, uint256 guild, uint8 kind, uint8 rank)
        external
        returns (uint256 tokenId)
    {
        if (msg.sender != minter) revert NotMinter();
        if (kind != KIND_VICTORY && kind != KIND_HONOUR) revert InvalidKind();
        tokenId = ++totalMinted;
        _banners[tokenId] = Banner({season: uint64(season), guild: uint64(guild), kind: kind, rank: rank});
        _mint(to, tokenId);
        emit BannerMinted(tokenId, to, season, guild, kind, rank);
    }

    function banner(uint256 tokenId) external view returns (Banner memory) {
        _requireOwned(tokenId);
        return _banners[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Banner memory b = _banners[tokenId];
        string memory kindName = b.kind == KIND_VICTORY ? "Victory" : "Honour";
        return string.concat(
            "data:application/json;utf8,{\"name\":\"Pacts ",
            kindName,
            " Banner #",
            Strings.toString(tokenId),
            "\",\"attributes\":[{\"trait_type\":\"season\",\"value\":",
            Strings.toString(b.season),
            "},{\"trait_type\":\"guild\",\"value\":",
            Strings.toString(b.guild),
            "},{\"trait_type\":\"kind\",\"value\":\"",
            kindName,
            "\"},{\"trait_type\":\"rank\",\"value\":",
            Strings.toString(b.rank),
            "}]}"
        );
    }
}
