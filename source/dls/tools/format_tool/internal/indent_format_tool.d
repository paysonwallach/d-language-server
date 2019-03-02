/*
 *Copyright (C) 2018 Laurent Tréguier
 *
 *This file is part of DLS.
 *
 *DLS is free software: you can redistribute it and/or modify
 *it under the terms of the GNU General Public License as published by
 *the Free Software Foundation, either version 3 of the License, or
 *(at your option) any later version.
 *
 *DLS is distributed in the hope that it will be useful,
 *but WITHOUT ANY WARRANTY; without even the implied warranty of
 *MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *GNU General Public License for more details.
 *
 *You should have received a copy of the GNU General Public License
 *along with DLS.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

module dls.tools.format_tool.internal.indent_format_tool;

import dls.protocol.definitions : Range;
import dls.tools.format_tool.internal.format_tool : FormatTool;

class IndentFormatTool : FormatTool
{
    import dls.protocol.definitions : Position, TextEdit;
    import dls.protocol.interfaces : FormattingOptions;
    import dls.util.uri : Uri;
    import dparse.lexer : Token;

    override TextEdit[] formatting(const Uri uri, const FormattingOptions options)
    {
        import dls.protocol.logger : logger;
        import dls.tools.format_tool.internal.indent_visitor : IndentVisitor;
        import dls.util.document : Document;
        import dparse.lexer : LexerConfig, StringBehavior, StringCache,
            WhitespaceBehavior, byToken, getTokensForParser, tok;
        import dparse.parser : parseModule;
        import dparse.rollback_allocator : RollbackAllocator;
        import std.algorithm : all, count, filter, sort;
        import std.array : appender;
        import std.ascii : isWhite;
        import std.utf : toUTF8;

        logger.info("Indenting %s", uri.path);

        auto result = appender!(TextEdit[]);
        const document = Document.get(uri);
        const data = document.toString();
        auto config = LexerConfig(uri.path, StringBehavior.source, WhitespaceBehavior.include);
        auto stringCache = StringCache(StringCache.defaultBucketCount);
        const tokens = getTokensForParser(data, config, &stringCache);
        auto commentTokens = byToken(data, config, &stringCache).filter!(
                t => t.type == tok!"comment");
        RollbackAllocator rollbackAllocator;
        auto visitor = new IndentVisitor();
        visitor.visit(parseModule(tokens, uri.path, &rollbackAllocator));

        auto indentLines = extractIndentLines(tokens);
        auto indentBegins = sort(indentLines.keys);
        auto indentEnds = sort(indentLines.values);
        size_t indents;

        foreach (line; 0 .. document.lines.length)
        {
            while (!indentEnds.empty && indentEnds.front == line + 1)
            {
                --indents;
                indentEnds.popFront();
            }

            auto shouldIndent = true;

            while (!commentTokens.empty && line >= commentTokens.front.line)
            {
                immutable text = commentTokens.front.text;
                immutable commentEndLine = commentTokens.front.line + text.count(
                        '\r') + text.count('\n') - text.count("\r\n");

                if (line < commentEndLine)
                {
                    shouldIndent = false;
                    break;
                }
                else
                {
                    commentTokens.popFront();
                }
            }

            const docLine = document.lines[line];
            shouldIndent &= !docLine.all!isWhite;

            if (shouldIndent)
            {
                auto indentRange = getIndentRange(docLine);
                auto edit = new TextEdit(indentRange);
                auto newText = new wchar[options.insertSpaces ? indents * options.tabSize : indents];
                newText[] = options.insertSpaces ? ' ' : '\t';

                if (newText != docLine[0 .. indentRange.end.character])
                {
                    edit.range.start.line = edit.range.end.line = line;
                    edit.newText = newText.toUTF8();
                    result ~= edit;
                }
            }

            while (!indentBegins.empty && indentBegins.front == line + 1)
            {
                ++indents;
                indentBegins.popFront();
            }

            auto trailingWhitespaceRange = getTrailingWhitespaceRange(docLine);

            if (trailingWhitespaceRange.end.character - trailingWhitespaceRange.start.character > 0)
            {
                trailingWhitespaceRange.start.line = trailingWhitespaceRange.end.line = line;
                result ~= new TextEdit(trailingWhitespaceRange, "");
            }
        }

        return result.data;
    }

    private size_t[size_t] extractIndentLines(const Token[] tokens)
    {
        import dparse.lexer : tok;
        import std.algorithm : remove;
        import std.container : SList;

        SList!size_t indentPairBegins;
        size_t[size_t] indentLines;
        size_t currentLine;

        foreach (ref token; tokens)
        {
            switch (token.type)
            {
            case tok!"{", tok!"(", tok!"[":
                indentPairBegins.insertFront(token.line);
                break;

            case tok!"}", tok!")", tok!"]":
                if (indentPairBegins.empty)
                {
                    break;
                }

                if (token.line != indentPairBegins.front && indentPairBegins.front !in indentLines)
                {
                    indentLines[indentPairBegins.front] = token.line;

                    if (token.line == currentLine)
                    {
                        ++indentLines[indentPairBegins.front];
                    }
                }

                indentPairBegins.removeFront();
                break;

            default:
                break;
            }

            if (token.line > currentLine)
            {
                currentLine = token.line;
            }
        }

        return indentLines;
    }
}

private Range getIndentRange(const wstring line)
{
    import std.ascii : isWhite;
    import std.string : stripRight;

    auto result = new Range();
    immutable cleanLine = stripRight(line);

    while (result.end.character < cleanLine.length && isWhite(cleanLine[result.end.character]))
    {
        ++result.end.character;
    }

    return result;
}

private Range getTrailingWhitespaceRange(const wstring line)
{
    import std.algorithm : among;
    import std.ascii : isWhite;

    auto result = new Range();
    result.start.character = result.end.character = line.length;

    while (result.start.character > 0 && isWhite(line[result.start.character - 1]))
    {
        --result.start.character;

        if (line[result.start.character].among('\r', '\n'))
        {
            --result.end.character;
        }
    }

    return result;
}