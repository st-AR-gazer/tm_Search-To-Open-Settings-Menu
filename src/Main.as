string g_Query = "";
bool g_FocusNextFrame = false;
bool g_MenuWasOpen = false;

array<Meta::Plugin@> g_Plugins;
uint g_LastRefreshTime = 0;
const uint REFRESH_MS = 2000;

int g_SelectedIndex = -1;

int g_NavDelta = 0;

int g_PendingScrollSteps = 0;
int g_PendingScrollStartIdx = -1;

const bool ALPHA_PRIMARY = true;
const int BUFFER_ROWS = 2;
const float EDGE_MARGIN = 6.0f;

// Utils

void RefreshPlugins(bool force = false) {
    uint now = Time::Now;
    if (!force && now - g_LastRefreshTime < REFRESH_MS) return;
    g_Plugins = Meta::AllPlugins();
    g_LastRefreshTime = now;
}

int AbsI(int x) { return x < 0 ? -x : x; }
int ClampI(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
float ClampF(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

string lower(const string &in s) { return s.ToLower(); }

int FindNext(const string &in lname, const string &in lq, int start) {
    int n  = int(lname.Length);
    int qn = int(lq.Length);
    if (qn <= 0) return start;
    for (int i = start; i <= n - qn; i++) {
        if (lname.SubStr(i, qn) == lq) return i;
    }
    return -1;
}

string LowerNoSpaces(const string &in s) {
    string res = "";
    for (uint i = 0; i < uint(s.Length); i++) {
        string c = s.SubStr(i, 1);
        if (c != " " && c != "\t") res += c.ToLower();
    }
    return res;
}

bool IsInitialBoundary(const string &in name, int i) {
    if (i <= 0) return true;
    string prev = name.SubStr(i - 1, 1);
    string ch = name.SubStr(i, 1);
    bool prevIsWS = (prev == " " || prev == "\t");
    bool chIsUpper = (ch != ch.ToLower());
    return prevIsWS || chIsUpper;
}

void BuildInitials(const string &in name, string &out initials, array<int> &out pos) {
    initials = "";
    pos.RemoveRange(0, pos.Length);
    for (int i = 0; i < int(name.Length); i++) {
        if (!IsInitialBoundary(name, i)) continue;
        string ch = name.SubStr(i, 1);
        if (ch == " " || ch == "\t") continue;
        initials += ch.ToUpper();
        pos.InsertLast(i);
    }
}

string BuildLabelFromPositions(const string &in name, const array<int> &in matchPositions, int matchCount) {
    int n = int(name.Length);
    array<bool> isHit(uint(n));
    for (int k = 0; k < matchCount && k < int(matchPositions.Length); k++) {
        int p = matchPositions[k];
        if (p >= 0 && p < n) isHit[uint(p)] = true;
    }

    string res = "";
    for (int i = 0; i < n; i++) {
        res += (isHit[uint(i)] ? "\\$fff" : "\\$ccc") + name.SubStr(i, 1);
    }
    return res;
}

void SortMatchArrays(array<string>@ names,
                     array<uint>@   idxs,
                     array<int>@    firstPos,
                     array<string>@ lowerNames,
                     array<string>@ labels)
{
    for (uint i = 1; i < names.Length; i++) {
        string kName = names[i];
        string kLow  = lowerNames[i];
        uint   kIdx  = idxs[i];
        int    kPos  = firstPos[i];
        string kLbl  = labels[i];

        int j = int(i) - 1;
        while (j >= 0) {
            bool greater = false;
            if (ALPHA_PRIMARY) {
                if (lowerNames[uint(j)] > kLow) {
                    greater = true;
                } else if (lowerNames[uint(j)] == kLow && firstPos[uint(j)] > kPos) {
                    greater = true;
                }
            } else {
                if (firstPos[uint(j)] > kPos) {
                    greater = true;
                } else if (firstPos[uint(j)] == kPos && lowerNames[uint(j)] > kLow) {
                    greater = true;
                }
            }
            if (!greater) break;

            names[uint(j+1)]      = names[uint(j)];
            lowerNames[uint(j+1)] = lowerNames[uint(j)];
            idxs[uint(j+1)]       = idxs[uint(j)];
            firstPos[uint(j+1)]   = firstPos[uint(j)];
            labels[uint(j+1)]     = labels[uint(j)];
            j--;
        }

        names[uint(j+1)]      = kName;
        lowerNames[uint(j+1)] = kLow;
        idxs[uint(j+1)]       = kIdx;
        firstPos[uint(j+1)]   = kPos;
        labels[uint(j+1)]     = kLbl;
    }
}

int BuildColoredLabelAndFirstPos(const string &in name, const string &in query, string &out label) {
    int qn = int(query.Length);
    if (qn <= 0) { label = "\\$ccc" + name; return 0; }

    string lname = name.ToLower();
    string lq = query.ToLower();

    int firstPos = -1;
    int cursor = 0;
    label = "";

    while (true) {
        int pos = FindNext(lname, lq, cursor);
        if (pos < 0) break;

        if (firstPos < 0) firstPos = pos;
        if (pos > cursor) { label += "\\$ccc" + name.SubStr(cursor, pos - cursor); }

        label += "\\$fff" + name.SubStr(pos, qn);
        cursor = pos + qn;
    }

    if (cursor < int(name.Length)) { label += "\\$ccc" + name.SubStr(cursor); }
    if (firstPos < 0) { label = "\\$ccc" + name; }

    return firstPos;
}

void FindMatches(const string  &in  query,
                 array<string> &out names,
                 array<uint>   &out idxs,
                 array<int>    &out firstPos,
                 array<string> &out lowerNames,
                 array<string> &out labels)
{
    names.RemoveRange(0, names.Length);
    idxs.RemoveRange(0, idxs.Length);
    firstPos.RemoveRange(0, firstPos.Length);
    lowerNames.RemoveRange(0, lowerNames.Length);
    labels.RemoveRange(0, labels.Length);

    array<string> n_sub, n_init, l_sub, l_init, lbl_sub, lbl_init;
    array<uint>   i_sub, i_init;
    array<int>    p_sub, p_init;

    string lq            = query.ToLower();
    string lqNoSpaces    = LowerNoSpaces(query);
    bool   hasQuery      = (query.Length > 0);
    bool   hasQueryNoSp  = (lqNoSpaces.Length > 0);

    for (uint i = 0; i < g_Plugins.Length; i++) {
        Meta::Plugin@ p = g_Plugins[i];
        string name = p.Name;
        string low  = name.ToLower();

        if (!hasQuery) {
            n_sub.InsertLast(name);
            i_sub.InsertLast(i);
            p_sub.InsertLast(0);
            l_sub.InsertLast(low);
            lbl_sub.InsertLast("\\$ccc" + name);
            continue;
        }

        int pos = -1;
        for (int start = 0; start <= int(low.Length) - int(lq.Length); start++) {
            if (low.SubStr(start, int(lq.Length)) == lq) { pos = start; break; }
        }

        if (pos >= 0) {
            string lbl;
            int first = BuildColoredLabelAndFirstPos(name, query, lbl);
            n_sub.InsertLast(name);
            i_sub.InsertLast(i);
            p_sub.InsertLast(first);
            l_sub.InsertLast(low);
            lbl_sub.InsertLast(lbl);
            continue;
        }

        if (hasQueryNoSp) {
            string initials;
            array<int> initPos;
            BuildInitials(name, initials, initPos);
            string il = initials.ToLower();

            if (int(il.Length) >= int(lqNoSpaces.Length) && il.SubStr(0, int(lqNoSpaces.Length)) == lqNoSpaces) {
                string lbl2 = BuildLabelFromPositions(name, initPos, int(lqNoSpaces.Length));
                int firstIdx = (initPos.Length > 0 ? initPos[0] : 0);

                n_init.InsertLast(name);
                i_init.InsertLast(i);
                p_init.InsertLast(firstIdx);
                l_init.InsertLast(low);
                lbl_init.InsertLast(lbl2);
                continue;
            }
        }
    }

    SortMatchArrays(@n_sub, @i_sub, @p_sub, @l_sub, @lbl_sub);
    SortMatchArrays(@n_init, @i_init, @p_init, @l_init, @lbl_init);

    for (uint k = 0; k < n_sub.Length; k++) {
        names.InsertLast(n_sub[k]);
        idxs.InsertLast(i_sub[k]);
        firstPos.InsertLast(p_sub[k]);
        lowerNames.InsertLast(l_sub[k]);
        labels.InsertLast(lbl_sub[k]);
    }
    for (uint k = 0; k < n_init.Length; k++) {
        names.InsertLast(n_init[k]);
        idxs.InsertLast(i_init[k]);
        firstPos.InsertLast(p_init[k]);
        lowerNames.InsertLast(l_init[k]);
        labels.InsertLast(lbl_init[k]);
    }
}

Meta::Plugin@ ResolveTarget(const string &in query) {
    array<string> names;
    array<string> lowerNames;
    array<string> labels;
    array<uint>   idxs;
    array<int>    firstPos;

    FindMatches(query, names, idxs, firstPos, lowerNames, labels);
    if (names.Length == 0) return null;

    string lq = query.ToLower();
    for (uint k = 0; k < names.Length; k++) {
        if (lowerNames[k] == lq) return g_Plugins[idxs[k]];
    }
    if (names.Length == 1) return g_Plugins[idxs[0]];
    return null;
}

void TryOpen() {
    Meta::Plugin@ target = ResolveTarget(g_Query);
    if (target is null) { log("Ambiguous or no match for: '" + g_Query + "'", LogLevel::Warn, 276, "TryOpen"); return; }
    Meta::OpenSettings(target);
}

void TryOpenUsingSelectionOrQuery(const array<uint>@ idxs) {
    if (g_SelectedIndex >= 0 && g_SelectedIndex < int(idxs.Length)) {
        Meta::Plugin@ target = g_Plugins[idxs[uint(g_SelectedIndex)]];
        Meta::OpenSettings(target);
        return;
    }
    TryOpen();
}

void OnInputCB(UI::InputTextCallbackData@ data) {
    if (data.EventFlag == UI::InputTextFlags::CallbackHistory) {
        if (data.EventKey == UI::Key::UpArrow)   g_NavDelta += -1;
        if (data.EventKey == UI::Key::DownArrow) g_NavDelta += +1;
    }
}

// Render

void RenderMenuMain() {
    if (UI::BeginMenu("\\$cf9" + Icons::Cogs + "\\$z Open Settings by Name##opsn")) {
        if (!g_MenuWasOpen) g_FocusNextFrame = true;
        g_MenuWasOpen = true;

        RefreshPlugins();

        UI::SetNextItemWidth(360);
        if (g_FocusNextFrame) { UI::SetKeyboardFocusHere(); g_FocusNextFrame = false; }

        string prevQuery = g_Query;

        int flags = UI::InputTextFlags::AutoSelectAll
                  | UI::InputTextFlags::EnterReturnsTrue
                  | UI::InputTextFlags::CallbackHistory;

        bool submitted = false;
        g_Query = UI::InputText("###opsn.query", g_Query, submitted, flags, UI::InputTextCallback(OnInputCB));

        bool goClicked = false;
        UI::SameLine();
        if (UI::Button(Icons::AngleRight + "##opsn.go")) goClicked = true;

        UI::Dummy(vec2(0, 3));
        UI::TextDisabled("["+Icons::ArrowDown+"/"+Icons::ArrowUp+"] select  *  [Enter] open  *  [Click] open");

        array<string> names;
        array<string> labels;
        array<string> lowerNames;
        array<uint>   idxs;
        array<int>    fpos;
        FindMatches(g_Query, names, idxs, fpos, lowerNames, labels);

        if (g_Query != prevQuery) g_SelectedIndex = -1;

        int steps = g_NavDelta; g_NavDelta = 0;
        g_PendingScrollSteps    = steps;
        g_PendingScrollStartIdx = g_SelectedIndex;

        int remaining = AbsI(steps);
        int sgn = (steps > 0) ? +1 : (steps < 0 ? -1 : 0);
        while (remaining-- > 0 && names.Length > 0) {
            if (g_SelectedIndex < 0) {
                g_SelectedIndex = (sgn > 0) ? 0 : int(names.Length) - 1;
            } else {
                g_SelectedIndex = (g_SelectedIndex + sgn + int(names.Length)) % int(names.Length);
            }
        }

        if (submitted || goClicked) {
            TryOpenUsingSelectionOrQuery(idxs);
            if (submitted) g_FocusNextFrame = true;
        }

        UI::Dummy(vec2(0, 4));

        const int MAX_VISIBLE_ROWS = 10;
        float rowHguess = UI::GetFrameHeightWithSpacing();
        float pad = 6.0f;
        float maxH = Math::Min(MAX_VISIBLE_ROWS * rowHguess + pad, 260.0f);
        float desiredH = names.Length > 0 ? Math::Min(maxH, names.Length * rowHguess + pad) : rowHguess + pad;

        UI::TextDisabled(Icons::List + "  Matches (" + names.Length + "):");
        UI::Dummy(vec2(0, 2));

        if (UI::BeginChild("##opsn.matches", vec2(360, desiredH))) {
            if (names.Length == 0) {
                g_SelectedIndex = -1;
            } else if (g_SelectedIndex >= int(names.Length)) {
                g_SelectedIndex = int(names.Length) - 1;
            }

            array<float> rowStartY;
            array<float> rowEndY;
            array<float> rowHeight;
            rowStartY.Resize(names.Length);
            rowEndY.Resize(names.Length);
            rowHeight.Resize(names.Length);

            for (uint i = 0; i < names.Length; i++) {
                float startY = UI::GetCursorPos().y;

                bool isSel = (int(i) == g_SelectedIndex);
                string label = labels[i] + "##opsn.item." + i;

                if (UI::Selectable(label, isSel)) Meta::OpenSettings(g_Plugins[idxs[i]]);

                float endY = UI::GetCursorPos().y;
                rowStartY[i] = startY;
                rowEndY[i]   = endY;
                rowHeight[i] = Math::Max(0.0f, endY - startY);
            }

            if (g_PendingScrollSteps != 0 && names.Length > 0) {
                int idxStart = g_PendingScrollStartIdx;
                int count    = AbsI(g_PendingScrollSteps);
                int d        = (g_PendingScrollSteps > 0) ? +1 : -1;

                float scrollY = UI::GetScrollY();
                float viewH   = UI::GetWindowSize().y;

                for (int s = 0; s < count; s++) {
                    if (idxStart < 0) {
                        idxStart = (d > 0) ? 0 : int(names.Length) - 1;
                    } else {
                        idxStart = (idxStart + d + int(names.Length)) % int(names.Length);
                    }

                    if (d > 0) {
                        int bufIdx = ClampI(idxStart + BUFFER_ROWS, 0, int(names.Length) - 1);
                        float safeBottom = scrollY + viewH - EDGE_MARGIN;

                        if (rowEndY[bufIdx] > safeBottom) {
                            float delta = rowHeight[bufIdx];
                            scrollY = Math::Min(scrollY + delta, UI::GetScrollMaxY());
                            UI::SetScrollY(scrollY);
                        }
                    } else {
                        int bufIdx = ClampI(idxStart - BUFFER_ROWS, 0, int(names.Length) - 1);
                        float safeTop = scrollY + EDGE_MARGIN;

                        if (rowStartY[bufIdx] < safeTop) {
                            float delta = rowHeight[bufIdx];
                            scrollY = Math::Max(scrollY - delta, 0.0f);
                            UI::SetScrollY(scrollY);
                        }
                    }
                }
                g_PendingScrollSteps = 0;
            }

            bool movedByKeysThisFrame = (g_PendingScrollStartIdx != g_SelectedIndex);
            if (movedByKeysThisFrame && names.Length > 0 && g_SelectedIndex >= 0) {
                float scrollY = UI::GetScrollY();
                float viewH   = UI::GetWindowSize().y;
                float topLim  = scrollY + EDGE_MARGIN;
                float botLim  = scrollY + viewH - EDGE_MARGIN;

                float selTop  = rowStartY[uint(g_SelectedIndex)];
                float selBot  = rowEndY[uint(g_SelectedIndex)];

                if (selTop < topLim) {
                    int bufIdx   = ClampI(g_SelectedIndex - BUFFER_ROWS, 0, int(names.Length) - 1);
                    float target = rowStartY[uint(bufIdx)] - EDGE_MARGIN;
                    float snapped = Math::Max(0.0f, Math::Min(target, UI::GetScrollMaxY()));
                    UI::SetScrollY(snapped);
                } else if (selBot > botLim) {
                    int bufIdx   = ClampI(g_SelectedIndex + BUFFER_ROWS, 0, int(names.Length) - 1);
                    float target = rowEndY[uint(bufIdx)] - viewH + EDGE_MARGIN;
                    float snapped = Math::Max(0.0f, Math::Min(target, UI::GetScrollMaxY()));
                    UI::SetScrollY(snapped);
                }
            }

            if (names.Length == 0) UI::TextDisabled(Icons::Times + "  No matches");
        }
        UI::EndChild();
        UI::EndMenu();
    } else {
        g_MenuWasOpen = false;
    }
}
