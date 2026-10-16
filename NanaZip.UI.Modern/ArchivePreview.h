// Read-only, bounded archive directory preview for the modern context menu.
#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace NanaZip::ShellExtension::Preview
{
    enum class Status { Unsupported, Ready, Unavailable, Limited };
    struct Node
    {
        std::wstring Name;
        bool Directory = false;
        std::vector<Node> Children;
        std::map<std::wstring, size_t> Index;
    };
    struct Result
    {
        Status State = Status::Unavailable;
        Node Root;
    };
    struct Row
    {
        std::wstring Name;
        unsigned Depth;
        bool Directory;
    };
    struct Rows
    {
        std::vector<Row> Items;
        bool Truncated = false;
    };
    bool Supports(const std::wstring& path);
    Result Read(const std::wstring& path, const std::wstring& corePath,
        std::uint64_t budgetMilliseconds = 350);
    Rows Flatten(const Result& result, size_t maximumRows = 12, unsigned maximumDepth = 3);
}
