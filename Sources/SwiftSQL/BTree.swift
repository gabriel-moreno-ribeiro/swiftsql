import Foundation

/// A B+tree of fixed-size rows keyed by Int64, stored in pages.
///
/// Page layout (all integers little-endian):
///   common header:  type(1)  isRoot(1)  parent(4)              = 6 bytes
///   leaf:           numCells(4) nextLeaf(4) | cells: key(8) + row(rowSize)
///   internal:       numKeys(4) rightChild(4) | pairs: child(4) + key(8)
///
/// Keys in an internal node are the maximum key of the child to their left,
/// and rightChild holds everything greater. Leaves are linked for scans.
public final class BTree {
    private enum NodeType: UInt8 { case internalNode = 0, leaf = 1 }

    private static let headerSize = 6
    private static let leafHeaderSize = headerSize + 8
    private static let internalHeaderSize = headerSize + 8
    private static let internalCellSize = 12
    private static let internalMaxKeys = (pageSize - internalHeaderSize) / internalCellSize

    public let pager: Pager
    public let rowSize: Int
    public let rootPage: Int
    private let leafCellSize: Int
    private let leafMaxCells: Int

    public init(pager: Pager, rowSize: Int, rootPage: Int = 0) throws {
        guard rowSize > 0, rowSize + 8 <= pageSize - BTree.leafHeaderSize - 8 else {
            throw DatabaseError.schema("row size \(rowSize) does not fit in a page")
        }
        self.pager = pager
        self.rowSize = rowSize
        self.rootPage = rootPage
        leafCellSize = 8 + rowSize
        leafMaxCells = (pageSize - BTree.leafHeaderSize) / leafCellSize
        if pager.pageCount == 0 {
            let root = pager.allocate()
            var page = Data(count: pageSize)
            BTree.initLeaf(&page, isRoot: true)
            pager.write(root, page)
        }
    }

    // MARK: node accessors

    private static func initLeaf(_ page: inout Data, isRoot: Bool) {
        page[0] = NodeType.leaf.rawValue
        page[1] = isRoot ? 1 : 0
        page.writeUInt32(0, at: 2)
        page.writeUInt32(0, at: 6)   // numCells
        page.writeUInt32(0, at: 10)  // nextLeaf (0 = none; page 0 is always the root)
    }

    private static func initInternal(_ page: inout Data, isRoot: Bool) {
        page[0] = NodeType.internalNode.rawValue
        page[1] = isRoot ? 1 : 0
        page.writeUInt32(0, at: 2)
        page.writeUInt32(0, at: 6)   // numKeys
        page.writeUInt32(0, at: 10)  // rightChild
    }

    private func isLeaf(_ page: Data) -> Bool { page[page.startIndex] == NodeType.leaf.rawValue }
    private func parent(_ page: Data) -> Int { Int(page.readUInt32(at: 2)) }
    private func numCells(_ page: Data) -> Int { Int(page.readUInt32(at: 6)) }
    private func nextLeaf(_ page: Data) -> Int { Int(page.readUInt32(at: 10)) }
    private func leafKey(_ page: Data, _ i: Int) -> Int64 { page.readInt64(at: BTree.leafHeaderSize + i * leafCellSize) }
    private func leafRow(_ page: Data, _ i: Int) -> Data { page.slice(BTree.leafHeaderSize + i * leafCellSize + 8, rowSize) }
    private func numKeys(_ page: Data) -> Int { Int(page.readUInt32(at: 6)) }
    private func rightChild(_ page: Data) -> Int { Int(page.readUInt32(at: 10)) }
    private func childAt(_ page: Data, _ i: Int) -> Int { Int(page.readUInt32(at: BTree.internalHeaderSize + i * BTree.internalCellSize)) }
    private func keyAt(_ page: Data, _ i: Int) -> Int64 { page.readInt64(at: BTree.internalHeaderSize + i * BTree.internalCellSize + 4) }

    private func setLeafCell(_ page: inout Data, _ i: Int, key: Int64, row: Data) {
        let offset = BTree.leafHeaderSize + i * leafCellSize
        page.writeInt64(key, at: offset)
        page.replace(at: offset + 8, with: row)
    }

    private func setInternalCell(_ page: inout Data, _ i: Int, child: Int, key: Int64) {
        let offset = BTree.internalHeaderSize + i * BTree.internalCellSize
        page.writeUInt32(UInt32(child), at: offset)
        page.writeInt64(key, at: offset + 4)
    }

    /// Largest key stored under a node (used when promoting keys upward).
    private func maxKey(_ pageNumber: Int) throws -> Int64 {
        let page = try pager.page(pageNumber)
        if isLeaf(page) { return leafKey(page, numCells(page) - 1) }
        return try maxKey(rightChild(page))
    }

    // MARK: search

    /// Finds the leaf page that does or would contain `key`, and the cell index within it.
    public func find(_ key: Int64) throws -> (page: Int, cell: Int, found: Bool) {
        var pageNumber = rootPage
        while true {
            let page = try pager.page(pageNumber)
            if isLeaf(page) {
                let (index, found) = leafSearch(page, key)
                return (pageNumber, index, found)
            }
            pageNumber = internalChild(page, for: key)
        }
    }

    private func leafSearch(_ page: Data, _ key: Int64) -> (Int, Bool) {
        var lo = 0
        var hi = numCells(page)
        while lo < hi {
            let mid = (lo + hi) / 2
            let k = leafKey(page, mid)
            if k == key { return (mid, true) }
            if k < key { lo = mid + 1 } else { hi = mid }
        }
        return (lo, false)
    }

    private func internalChild(_ page: Data, for key: Int64) -> Int {
        let n = numKeys(page)
        var lo = 0
        var hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyAt(page, mid) >= key { hi = mid } else { lo = mid + 1 }
        }
        return lo == n ? rightChild(page) : childAt(page, lo)
    }

    // MARK: insert / update / delete

    public func insert(key: Int64, row: Data) throws {
        precondition(row.count == rowSize)
        let (pageNumber, index, found) = try find(key)
        if found { throw DatabaseError.constraint("duplicate key \(key)") }
        var page = try pager.page(pageNumber)
        if numCells(page) >= leafMaxCells {
            try splitLeafAndInsert(pageNumber, page, index, key, row)
            return
        }
        // shift cells right and insert
        let n = numCells(page)
        if index < n {
            let start = BTree.leafHeaderSize + index * leafCellSize
            let bytes = page.slice(start, (n - index) * leafCellSize)
            page.replace(at: start + leafCellSize, with: bytes)
        }
        setLeafCell(&page, index, key: key, row: row)
        page.writeUInt32(UInt32(n + 1), at: 6)
        pager.write(pageNumber, page)
    }

    public func update(key: Int64, row: Data) throws -> Bool {
        let (pageNumber, index, found) = try find(key)
        guard found else { return false }
        var page = try pager.page(pageNumber)
        setLeafCell(&page, index, key: key, row: row)
        pager.write(pageNumber, page)
        return true
    }

    /// Removes a key from its leaf. Leaves are allowed to become empty (no rebalancing).
    public func delete(key: Int64) throws -> Bool {
        let (pageNumber, index, found) = try find(key)
        guard found else { return false }
        var page = try pager.page(pageNumber)
        let n = numCells(page)
        if index < n - 1 {
            let start = BTree.leafHeaderSize + (index + 1) * leafCellSize
            let bytes = page.slice(start, (n - index - 1) * leafCellSize)
            page.replace(at: start - leafCellSize, with: bytes)
        }
        page.writeUInt32(UInt32(n - 1), at: 6)
        pager.write(pageNumber, page)
        return true
    }

    private func splitLeafAndInsert(_ oldNumber: Int, _ oldPage: Data, _ index: Int, _ key: Int64, _ row: Data) throws {
        // gather all cells including the new one, in order
        var cells: [(Int64, Data)] = []
        for i in 0..<numCells(oldPage) { cells.append((leafKey(oldPage, i), leafRow(oldPage, i))) }
        cells.insert((key, row), at: index)
        let leftCount = (cells.count + 1) / 2

        let newNumber = pager.allocate()
        var left = Data(count: pageSize)
        var right = Data(count: pageSize)
        BTree.initLeaf(&left, isRoot: false)
        BTree.initLeaf(&right, isRoot: false)
        for (i, c) in cells[..<leftCount].enumerated() { setLeafCell(&left, i, key: c.0, row: c.1) }
        for (i, c) in cells[leftCount...].enumerated() { setLeafCell(&right, i, key: c.0, row: c.1) }
        left.writeUInt32(UInt32(leftCount), at: 6)
        right.writeUInt32(UInt32(cells.count - leftCount), at: 6)
        right.writeUInt32(UInt32(nextLeaf(oldPage)), at: 10)
        left.writeUInt32(UInt32(newNumber), at: 10)
        let leftMax = cells[leftCount - 1].0

        if oldPage[oldPage.startIndex + 1] == 1 {
            // splitting the root: old page becomes an internal root, children go to new pages
            let leftNumber = pager.allocate()
            left.writeUInt32(UInt32(oldNumber), at: 2)
            right.writeUInt32(UInt32(oldNumber), at: 2)
            pager.write(leftNumber, left)
            pager.write(newNumber, right)
            var root = Data(count: pageSize)
            BTree.initInternal(&root, isRoot: true)
            root.writeUInt32(1, at: 6)
            root.writeUInt32(UInt32(newNumber), at: 10)
            setInternalCell(&root, 0, child: leftNumber, key: leftMax)
            pager.write(oldNumber, root)
            try fixChildParents(leftNumber)
            try fixChildParents(newNumber)
        } else {
            let parentNumber = parent(oldPage)
            left.writeUInt32(UInt32(parentNumber), at: 2)
            right.writeUInt32(UInt32(parentNumber), at: 2)
            pager.write(oldNumber, left)
            pager.write(newNumber, right)
            try insertIntoInternal(parentNumber, leftChild: oldNumber, leftMax: leftMax, rightChild: newNumber)
        }
    }

    /// After a split, `leftChild` (already in the parent) now holds keys up to `leftMax`
    /// and `rightChild` holds the rest. Adds the new separator to the parent, splitting it if full.
    private func insertIntoInternal(_ parentNumber: Int, leftChild: Int, leftMax: Int64, rightChild newChild: Int) throws {
        var page = try pager.page(parentNumber)
        let n = numKeys(page)

        // where does leftChild live? either as a cell or as the right child
        var position = n
        for i in 0..<n where childAt(page, i) == leftChild { position = i }

        var pairs: [(child: Int, key: Int64)] = (0..<n).map { (childAt(page, $0), keyAt(page, $0)) }
        var right = rightChild(page)
        if position == n {
            // leftChild was the right child: it becomes a cell, new child becomes the right child
            pairs.append((leftChild, leftMax))
            right = newChild
        } else {
            let oldKey = pairs[position].key
            pairs[position] = (leftChild, leftMax)
            pairs.insert((newChild, oldKey), at: position + 1)
        }

        if pairs.count <= BTree.internalMaxKeys {
            page.writeUInt32(UInt32(pairs.count), at: 6)
            page.writeUInt32(UInt32(right), at: 10)
            for (i, p) in pairs.enumerated() { setInternalCell(&page, i, child: p.child, key: p.key) }
            pager.write(parentNumber, page)
            try setParent(of: newChild, to: parentNumber)
            return
        }

        // split the internal node: left keeps the first half, the middle key moves up
        let mid = pairs.count / 2
        let leftPairs = Array(pairs[..<mid])
        let separator = pairs[mid]
        let rightPairs = Array(pairs[(mid + 1)...])
        let leftRight = separator.child
        let isRoot = page[page.startIndex + 1] == 1
        let grandParent = parent(page)

        let rightNumber = pager.allocate()
        var rightPage = Data(count: pageSize)
        BTree.initInternal(&rightPage, isRoot: false)
        rightPage.writeUInt32(UInt32(rightPairs.count), at: 6)
        rightPage.writeUInt32(UInt32(right), at: 10)
        for (i, p) in rightPairs.enumerated() { setInternalCell(&rightPage, i, child: p.child, key: p.key) }

        var leftPage = Data(count: pageSize)
        BTree.initInternal(&leftPage, isRoot: false)
        leftPage.writeUInt32(UInt32(leftPairs.count), at: 6)
        leftPage.writeUInt32(UInt32(leftRight), at: 10)
        for (i, p) in leftPairs.enumerated() { setInternalCell(&leftPage, i, child: p.child, key: p.key) }

        if isRoot {
            let leftNumber = pager.allocate()
            leftPage.writeUInt32(UInt32(parentNumber), at: 2)
            rightPage.writeUInt32(UInt32(parentNumber), at: 2)
            pager.write(leftNumber, leftPage)
            pager.write(rightNumber, rightPage)
            var root = Data(count: pageSize)
            BTree.initInternal(&root, isRoot: true)
            root.writeUInt32(1, at: 6)
            root.writeUInt32(UInt32(rightNumber), at: 10)
            setInternalCell(&root, 0, child: leftNumber, key: separator.key)
            pager.write(parentNumber, root)
            try fixChildParents(leftNumber)
            try fixChildParents(rightNumber)
        } else {
            leftPage.writeUInt32(UInt32(grandParent), at: 2)
            rightPage.writeUInt32(UInt32(grandParent), at: 2)
            pager.write(parentNumber, leftPage)
            pager.write(rightNumber, rightPage)
            try fixChildParents(rightNumber)
            try insertIntoInternal(grandParent, leftChild: parentNumber, leftMax: separator.key, rightChild: rightNumber)
        }
    }

    private func setParent(of pageNumber: Int, to parentNumber: Int) throws {
        var page = try pager.page(pageNumber)
        page.writeUInt32(UInt32(parentNumber), at: 2)
        pager.write(pageNumber, page)
    }

    private func fixChildParents(_ pageNumber: Int) throws {
        let page = try pager.page(pageNumber)
        guard !isLeaf(page) else { return }
        for i in 0..<numKeys(page) { try setParent(of: childAt(page, i), to: pageNumber) }
        try setParent(of: rightChild(page), to: pageNumber)
    }

    // MARK: scanning

    /// Visits every (key, row) in key order.
    public func scan(_ body: (Int64, Data) throws -> Bool) throws {
        var pageNumber = rootPage
        var page = try pager.page(pageNumber)
        while !isLeaf(page) {
            pageNumber = childAt(page, 0)
            if numKeys(page) == 0 { pageNumber = rightChild(page) }
            page = try pager.page(pageNumber)
        }
        while true {
            for i in 0..<numCells(page) {
                if try !body(leafKey(page, i), leafRow(page, i)) { return }
            }
            let next = nextLeaf(page)
            if next == 0 { return }
            page = try pager.page(next)
        }
    }

    public func get(_ key: Int64) throws -> Data? {
        let (pageNumber, index, found) = try find(key)
        guard found else { return nil }
        return leafRow(try pager.page(pageNumber), index)
    }

    public func count() throws -> Int {
        var n = 0
        try scan { _, _ in n += 1; return true }
        return n
    }

    /// Depth of the tree (1 for a single leaf), for diagnostics and tests.
    public func height() throws -> Int {
        var h = 1
        var page = try pager.page(rootPage)
        while !isLeaf(page) {
            h += 1
            page = try pager.page(rightChild(page))
        }
        return h
    }
}
