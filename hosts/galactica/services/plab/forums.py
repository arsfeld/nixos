"""The tracker's video forums, grouped under the names the page shows as categories."""

# Forums holding video releases. Left out on purpose: photos and magazines
# (1723 1726 883 1728 1729 38 1757 1735 1731 1802), manga/art/comics (1745 1760 1781
# 1296), games (1838 1750 1756 1869 1785 1790 1827 1870 1828 1829 1865), and rules,
# discussion and archive forums (1817 1863 1864 1683 1720 1815 1692).
GROUPS = {
    "Erotic & softcore": (1670, 1768, 60, 1671, 1644),
    "Full-length movies": (
        1672, 1111, 508, 555, 1845, 1673, 1112, 1718, 553, 1143, 1646,
        1717, 1851, 1713, 512, 1712, 1775, 1450,
    ),
    "Russian": (1674, 902, 1675, 36, 1830, 1803, 1831, 1877, 1878, 1741, 1676),
    "Clips and siterips": (
        1677, 1780, 1110, 1678, 1124, 1784, 1769, 1793, 1797, 1804, 1819, 1825, 1836, 1842,
        1846, 1857, 1861, 1867, 1872, 1875, 1451, 1788, 1789, 1792, 1798, 1805, 1820, 1826,
        1837, 1843, 1847, 1856, 1862, 1868, 1873, 1876, 1707, 1874, 284, 1853,
    ),
    "VR": (1823,),
    "JAV": (1800, 1801, 1719, 997, 1818, 1849),
    "Hentai and cartoon video": (1679, 1740, 1834, 1752, 1711),
    "Special interest": (
        11, 1715, 1680, 1758, 1682, 1733, 1754, 1734, 1791, 509, 1859, 1685, 1762, 1881, 1681,
    ),
    "Gay": (1688, 903, 1765, 1767, 1755, 1787, 1763, 1777, 1691),
}

FORUMS = tuple(f for ids in GROUPS.values() for f in ids)

_NAMES = {f: name for name, ids in GROUPS.items() for f in ids}


def category(forum_id):
    return _NAMES.get(forum_id, "Other")
