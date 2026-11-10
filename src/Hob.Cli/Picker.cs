namespace Hob.Cli;

internal sealed record Pick(Place Place, int Index, string Query);

/// <summary>
/// Drawn inline under the prompt rather than full-screen, and erased afterwards, so the scrollback keeps only
/// the command you typed. Positions are relative (save/restore cursor), so it never needs to know where on the
/// screen it is.
/// </summary>
internal static class Picker
{
    private const string Esc = "\u001b";

    /// <param name="open">
    /// Opens a pick in a new terminal (a tab when the bool is true) and returns what to tell you. The picker stays
    /// up afterwards, so several places can be opened from one <c>hob to</c>. Null leaves only Enter.
    /// </param>
    /// <param name="tabs">Whether there are tabs to open into, which only Windows Terminal has.</param>
    public static Pick? Show(ITerminal term, IReadOnlyList<Place> places, string query, Func<string, List<Place>> match, Func<Pick, bool, string>? open = null, bool tabs = false)
    {
        string keys = open is null ? "Up/Down move   Enter jump   Esc cancel"
            : tabs ? "Enter jump   Ctrl+Enter window (+Shift tab)   Esc cancel"
            : "Enter jump   Ctrl+Enter window   Esc cancel";
        int visible = Math.Max(1, Math.Min(10, Math.Min(places.Count, term.Height - 4)));
        int rows = visible + 2;
        int width = Math.Max(20, term.Width - 1);
        int nameWidth = Math.Min(24, places.Max(p => p.Qualified.Length) + 2);

        // Make room first, so drawing never scrolls, then remember the top-left of the area.
        term.Write("\r" + new string('\n', rows - 1) + $"{Esc}[{rows - 1}A{Esc}7");
        int selected = 0, offset = 0;
        string? status = null;
        try
        {
            while (true)
            {
                var hits = match(query);
                selected = Math.Max(0, Math.Min(selected, hits.Count - 1));
                if (selected < offset) offset = selected;
                if (selected >= offset + visible) offset = selected - visible + 1;

                var frame = new System.Text.StringBuilder($"{Esc}[?25l{Esc}8");
                Row(frame, $"to> {query}", width, $"{Esc}[36m");
                for (int r = 0; r < visible; r++)
                {
                    int i = offset + r;
                    string text = i < hits.Count ? "  " + hits[i].Qualified.PadRight(nameWidth) + hits[i].Path : "";
                    if (i == selected && hits.Count > 0) Row(frame, ">" + text[1..], width, $"{Esc}[30;46m");
                    else Row(frame, text, width, "");
                }
                if (status is not null) Row(frame, $"  {status}", width, $"{Esc}[33m", last: true);
                else Row(frame, $"  {hits.Count}/{places.Count}   {keys}", width, $"{Esc}[90m", last: true);
                frame.Append($"{Esc}8{Esc}[{Math.Min(4 + query.Length, width)}C{Esc}[?25h");
                term.Write(frame.ToString());

                var key = term.ReadKey();
                status = null;
                bool control = (key.Modifiers & ConsoleModifiers.Control) != 0;
                bool shift = (key.Modifiers & ConsoleModifiers.Shift) != 0;
                if (control && key.Key == ConsoleKey.C) return null;
                if (control && key.Key == ConsoleKey.U) { query = ""; selected = 0; continue; }
                if (control && key.Key == ConsoleKey.N) { selected++; continue; }
                if (control && key.Key == ConsoleKey.P) { selected--; continue; }
                switch (key.Key)
                {
                    // Shift+Enter alone is a window too, for terminals that keep Ctrl+Enter for themselves. Where
                    // neither modifier reaches the console, it is a plain jump.
                    case ConsoleKey.Enter when hits.Count > 0 && open is not null && (control || shift):
                        status = open(new Pick(hits[selected], selected, query), tabs && control && shift);
                        break;
                    case ConsoleKey.Enter when hits.Count > 0: return new Pick(hits[selected], selected, query);
                    case ConsoleKey.Escape: return null;
                    case ConsoleKey.UpArrow: selected--; break;
                    case ConsoleKey.DownArrow: selected++; break;
                    case ConsoleKey.PageUp: selected -= visible; break;
                    case ConsoleKey.PageDown: selected += visible; break;
                    case ConsoleKey.Backspace:
                        if (query.Length > 0) query = query[..^1];
                        selected = 0;
                        break;
                    default:
                        if (!char.IsControl(key.KeyChar)) { query += key.KeyChar; selected = 0; }
                        break;
                }
            }
        }
        finally
        {
            var clear = new System.Text.StringBuilder($"{Esc}8");
            for (int r = 0; r < rows; r++) clear.Append(r < rows - 1 ? $"{Esc}[2K{Esc}[1B" : $"{Esc}[2K");
            clear.Append($"{Esc}8{Esc}[?25h");
            term.Write(clear.ToString());
        }
    }

    private static void Row(System.Text.StringBuilder frame, string text, int width, string style, bool last = false)
    {
        if (text.Length > width) text = text[..(width - 3)] + "...";
        frame.Append('\r').Append(style).Append(text.PadRight(width)).Append($"{Esc}[0m");
        if (!last) frame.Append($"{Esc}[1B");
    }
}
