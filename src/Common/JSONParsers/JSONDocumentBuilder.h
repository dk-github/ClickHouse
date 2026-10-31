#pragma once

#include <base/types.h>
#include <base/defines.h>
#include <Common/PODArray.h>
#include <Common/JSONParsers/ElementTypes.h>

#include <bit>
#include <ostream>


namespace DB
{

/// A JSON document that is built by code instead of being parsed from text, for formats that decode values of
/// their own (e.g. Avro) and insert them into a JSON column without writing and parsing JSON text.
/// It has the same interface as SimdJSONParser and RapidJSONParser (Element, Array, Object), so it can be used
/// as their replacement in JSONExtractTree.
///
/// Like the tape of simdjson, the document is a flat array of nodes in pre-order, and every array or object
/// node knows where its subtree ends. Strings and keys are stored in one buffer. Both are reused by `clear`,
/// so building a document per row does not allocate once the buffers have grown.
class JSONDocumentBuilder
{
    struct Node
    {
        ElementType type;
        /// The key of an object member, in `chars`.
        UInt32 key_offset = 0;
        UInt32 key_size = 0;
        /// The index after the last node of the subtree.
        UInt32 end = 0;
        /// The number of elements of an array or object, the size of a string.
        UInt32 size = 0;
        /// The value of a number or bool, the offset of a string in `chars`.
        UInt64 value = 0;
    };

public:
    class Array;
    class Object;

    class Element
    {
    public:
        Element() = default;
        Element(const JSONDocumentBuilder * document_, UInt32 index_) : document(document_), index(index_) {}

        ElementType type() const { return node().type; }
        bool isInt64() const { return type() == ElementType::INT64; }
        bool isUInt64() const { return type() == ElementType::UINT64; }
        bool isDouble() const { return type() == ElementType::DOUBLE; }
        bool isString() const { return type() == ElementType::STRING; }
        bool isArray() const { return type() == ElementType::ARRAY; }
        bool isObject() const { return type() == ElementType::OBJECT; }
        bool isBool() const { return type() == ElementType::BOOL; }
        bool isNull() const { return type() == ElementType::NULL_VALUE; }

        Int64 getInt64() const { return std::bit_cast<Int64>(node().value); }
        UInt64 getUInt64() const { return node().value; }
        double getDouble() const { return std::bit_cast<double>(node().value); }
        bool getBool() const { return node().value != 0; }
        std::string_view getString() const { return document->getChars(node().value, node().size); }
        Array getArray() const;
        Object getObject() const;

        Element getElement() const { return *this; }

    private:
        friend class JSONDocumentBuilder;
        const Node & node() const { return document->nodes[index]; }

        const JSONDocumentBuilder * document = nullptr;
        UInt32 index = 0;
    };

    class Array
    {
    public:
        class Iterator
        {
        public:
            Iterator(const JSONDocumentBuilder * document_, UInt32 index_) : document(document_), index(index_) {}
            Element operator*() const { return {document, index}; }
            Iterator & operator++() { index = document->nodes[index].end; return *this; }
            Iterator operator++(int) { auto res = *this; ++*this; return res; } /// NOLINT
            friend bool operator==(const Iterator & left, const Iterator & right) { return left.index == right.index; }
            friend bool operator!=(const Iterator & left, const Iterator & right) { return !(left == right); }

        private:
            const JSONDocumentBuilder * document;
            UInt32 index;
        };

        explicit Array(const Element & element_) : element(element_) {}
        Iterator begin() const { return {element.document, element.index + 1}; }
        Iterator end() const { return {element.document, element.node().end}; }
        size_t size() const { return element.node().size; }
        Element operator[](size_t n) const
        {
            auto it = begin();
            for (size_t i = 0; i != n; ++i)
                ++it;
            return *it;
        }

    private:
        Element element;
    };

    using KeyValuePair = std::pair<std::string_view, Element>;

    class Object
    {
    public:
        class Iterator
        {
        public:
            Iterator(const JSONDocumentBuilder * document_, UInt32 index_) : document(document_), index(index_) {}
            KeyValuePair operator*() const
            {
                const auto & node = document->nodes[index];
                return {document->getChars(node.key_offset, node.key_size), Element(document, index)};
            }
            Iterator & operator++() { index = document->nodes[index].end; return *this; }
            Iterator operator++(int) { auto res = *this; ++*this; return res; } /// NOLINT
            friend bool operator==(const Iterator & left, const Iterator & right) { return left.index == right.index; }
            friend bool operator!=(const Iterator & left, const Iterator & right) { return !(left == right); }

        private:
            const JSONDocumentBuilder * document;
            UInt32 index;
        };

        explicit Object(const Element & element_) : element(element_) {}
        Iterator begin() const { return {element.document, element.index + 1}; }
        Iterator end() const { return {element.document, element.node().end}; }
        size_t size() const { return element.node().size; }

        bool find(std::string_view key, Element & result) const
        {
            for (auto [member_key, value] : *this)
            {
                if (member_key == key)
                {
                    result = value;
                    return true;
                }
            }
            return false;
        }

    private:
        Element element;
    };

    /// Building a document. Values are added in pre-order: a member of an object is preceded by `addKey`,
    /// and an array or object is closed by `finish` with the index that `startArray` or `startObject` returned.

    void clear()
    {
        nodes.clear();
        chars.clear();
    }

    void addKey(std::string_view key)
    {
        pending_key_offset = addChars(key);
        pending_key_size = static_cast<UInt32>(key.size());
    }

    void addNull() { addNode(ElementType::NULL_VALUE, 0); }
    void addBool(bool value) { addNode(ElementType::BOOL, value); }
    void addInt64(Int64 value) { addNode(ElementType::INT64, std::bit_cast<UInt64>(value)); }
    void addUInt64(UInt64 value) { addNode(ElementType::UINT64, value); }
    void addDouble(double value) { addNode(ElementType::DOUBLE, std::bit_cast<UInt64>(value)); }

    void addString(std::string_view value)
    {
        UInt64 offset = addChars(value);
        addNode(ElementType::STRING, offset).size = static_cast<UInt32>(value.size());
    }

    UInt32 startArray() { return startContainer(ElementType::ARRAY); }
    UInt32 startObject() { return startContainer(ElementType::OBJECT); }

    void finish(UInt32 index)
    {
        auto & node = nodes[index];
        node.end = static_cast<UInt32>(nodes.size());
        for (UInt32 child = index + 1; child != node.end; child = nodes[child].end)
            ++node.size;
    }

    /// The first value added.
    Element root() const { return {this, 0}; }

private:
    Node & addNode(ElementType type, UInt64 value)
    {
        auto index = static_cast<UInt32>(nodes.size());
        nodes.push_back(Node{.type = type, .key_offset = pending_key_offset, .key_size = pending_key_size, .end = index + 1, .value = value});
        pending_key_offset = 0;
        pending_key_size = 0;
        return nodes.back();
    }

    UInt32 startContainer(ElementType type)
    {
        auto index = static_cast<UInt32>(nodes.size());
        addNode(type, 0);
        return index;
    }

    UInt32 addChars(std::string_view value)
    {
        auto offset = static_cast<UInt32>(chars.size());
        chars.insert(value.data(), value.data() + value.size());
        return offset;
    }

    std::string_view getChars(UInt64 offset, size_t size) const { return {chars.data() + offset, size}; }

    PODArray<Node> nodes;
    PODArray<char> chars;
    UInt32 pending_key_offset = 0;
    UInt32 pending_key_size = 0;
};

inline JSONDocumentBuilder::Array JSONDocumentBuilder::Element::getArray() const
{
    return Array(*this);
}

inline JSONDocumentBuilder::Object JSONDocumentBuilder::Element::getObject() const
{
    return Object(*this);
}

inline ALWAYS_INLINE std::ostream & operator<<(std::ostream & out, JSONDocumentBuilder::Element)
{
    return out;
}

}
