// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SimpleSBT
 * @dev A simple Soul Bound Token (SBT) implementation
 * @notice This token cannot be transferred once minted - it's permanently bound to the recipient
 */
contract SimpleSBT is ERC721, Ownable {
    uint256 private _nextTokenId = 1;

    event SBTMinted(address indexed to, uint256 indexed tokenId);

    constructor(string memory name, string memory symbol)
        ERC721(name, symbol)
        Ownable(msg.sender)
    {}

    /**
     * @dev Mint an SBT to the caller's address
     * @notice Each address can only mint one SBT
     */
    function mint() external {
        uint256 tokenId = _nextTokenId++;
        _mint(msg.sender, tokenId);
        emit SBTMinted(msg.sender, tokenId);
    }

    /**
     * @dev Get the token ID owned by an address
     * @return tokenId The token ID, or 0 if no token is owned
     */
    function getTokenId(address owner) external view returns (uint256) {
        // Since each address can only have one token, we search for it
        for (uint256 i = 1; i < _nextTokenId; i++) {
            try this.ownerOf(i) returns (address tokenOwner) {
                if (tokenOwner == owner) {
                    return i;
                }
            } catch {
                // Token doesn't exist or burned, continue
                continue;
            }
        }

        return 0;
    }

    // Override _update to make the token soul-bound
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // Allow minting (from == address(0)) but not transfers
        if (from != address(0) && to != address(0)) {
            revert("SBT: Transfer not allowed - Soul Bound Token");
        }

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Override supportsInterface to include our custom functionality
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Get total number of tokens minted
     */
    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1;
    }
}