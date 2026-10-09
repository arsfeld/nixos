import unittest

import forums
import main

# Computed from main.py before the allowlist moved here.
PREVIOUS = (1670, 1768, 60, 1671, 1644, 1672, 1111, 508, 555, 1845, 1673, 1112, 1718, 553, 1143, 1646, 1717, 1851, 1713, 512, 1712, 1775, 1450, 1674, 902, 1675, 36, 1830, 1803, 1831, 1877, 1878, 1741, 1676, 1677, 1780, 1110, 1678, 1124, 1784, 1769, 1793, 1797, 1804, 1819, 1825, 1836, 1842, 1846, 1857, 1861, 1867, 1872, 1875, 1451, 1788, 1789, 1792, 1798, 1805, 1820, 1826, 1837, 1843, 1847, 1856, 1862, 1868, 1873, 1876, 1707, 1874, 284, 1853, 1823, 1800, 1801, 1719, 997, 1818, 1849, 1679, 1740, 1834, 1752, 1711, 11, 1715, 1680, 1758, 1682, 1733, 1754, 1734, 1791, 509, 1859, 1685, 1762, 1881, 1681, 1688, 903, 1765, 1767, 1755, 1787, 1763, 1777, 1691)


class Forums(unittest.TestCase):
    def test_flat_tuple_unchanged(self):
        self.assertEqual(forums.FORUMS, PREVIOUS)
        self.assertIsInstance(forums.FORUMS, tuple)

    def test_main_uses_it(self):
        self.assertIs(main.FORUMS, forums.FORUMS)

    def test_no_duplicates(self):
        self.assertEqual(len(set(forums.FORUMS)), len(forums.FORUMS))

    def test_group_order(self):
        self.assertEqual(list(forums.GROUPS), [
            "Erotic & softcore", "Full-length movies", "Russian", "Clips and siterips", "VR",
            "JAV", "Hentai and cartoon video", "Special interest", "Gay"])

    def test_category(self):
        self.assertEqual(forums.category(1670), "Erotic & softcore")
        self.assertEqual(forums.category(1875), "Clips and siterips")
        self.assertEqual(forums.category(1823), "VR")
        self.assertEqual(forums.category(1800), "JAV")
        self.assertEqual(forums.category(1691), "Gay")
        self.assertEqual(forums.category(999999), "Other")


if __name__ == "__main__":
    unittest.main()
