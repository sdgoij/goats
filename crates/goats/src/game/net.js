// Part 14/14 of the goat scene: the network bridge to the Rust host.
// ---- net ------------------------------------------------------------------
//
// The JS engine has no sockets, so all of the networking lives in the Rust host
// (`crates/goats/src/net.rs`). This part is only the scene end of a line-based
// bridge: intents accumulate in an outbox that `sceneNetDrain()` returns and
// clears once a frame, and events arrive through `sceneNetEvent(line)`, one JSON
// object per line. Both directions are plain text, so the harness can drive the
// whole thing without a socket or a peer.
//
// The events update a small local view (`netMode`, `netName`, `netRoster`) for
// the `net` and `who` commands, and print into the console's network stream.

const NET_OFF = "off";
let netMode = NET_OFF;      // "off" | "host" | "client"
let netName = "";           // this player's assigned name, once connected
let netTicket = "";         // the ticket to hand out, once hosting
let netRoster = [];         // names in the session, host first
let netOutbox = [];         // intent lines waiting for the host

function netQueue(intent) {
    netOutbox.push(JSON.stringify(intent));
}

// Called by the host once a frame; returns and clears the queued intents. An
// empty string means "nothing to send", which is the common case.
function sceneNetDrain() {
    if (netOutbox.length === 0) return "";
    const text = netOutbox.join("\n");
    netOutbox = [];
    return text;
}

function netStatus() {
    return { mode: netMode, name: netName, ticket: netTicket, roster: netRoster.slice() };
}

function netInSession() {
    return netMode !== NET_OFF;
}

// The default name to ask for when the player did not give one. The server has
// the final say, so this is only a request.
function netRequestedName(parts, index) {
    const requested = parts[index];
    return requested === undefined ? "" : requested;
}

// Says something. The server routes a leading `@name` as a whisper, so the line
// is queued exactly as typed. An empty reply means "nothing to report": the
// console should not print an `ok` after every chat line.
function netSay(text) {
    if (!netInSession()) return "error not in a session";
    const line = String(text).trim();
    if (line === "") return "error nothing to say";
    netQueue({ type: "say", text: line });
    return "";
}

// ---- intents ---------------------------------------------------------------

function netHost(parts) {
    if (netInSession()) return "error already in a session (leave first)";
    netQueue({ type: "host", name: netRequestedName(parts, 1) });
    consoleSystem("net: hosting ...");
    return "ok host";
}

function netJoin(parts) {
    if (netInSession()) return "error already in a session (leave first)";
    const ticket = parts[1];
    if (ticket === undefined) return "error connect expects a ticket";
    netQueue({ type: "join", ticket: ticket, name: netRequestedName(parts, 2) });
    consoleSystem("net: connecting ...");
    return "ok connect";
}

function netLeave() {
    if (!netInSession()) return "error not in a session";
    netQueue({ type: "close" });
    netReset();
    consoleSystem("net: leaving");
    return "ok leave";
}

function netReset() {
    netMode = NET_OFF;
    netName = "";
    netTicket = "";
    netRoster = [];
}

// ---- events ----------------------------------------------------------------

// One event line from the host. Unknown types are reported rather than ignored,
// so a bridge change cannot fail silently.
function sceneNetEvent(line) {
    let event;
    try {
        event = JSON.parse(String(line));
    } catch (error) {
        consoleNet("net: unreadable event " + String(line));
        return;
    }
    switch (event.type) {
        case "hosting":
            netMode = "host";
            netName = String(event.name);
            consoleNet("net: hosting as " + netName);
            break;
        case "ticket":
            netTicket = String(event.ticket);
            consoleNet("net: ticket " + netTicket);
            consoleSystem("net: `copy` puts the ticket on the clipboard");
            break;
        case "welcome":
            netMode = "client";
            netName = String(event.name);
            consoleNet("net: joined as " + netName);
            break;
        case "joined":
            consoleNet("net: " + event.name + " joined");
            break;
        case "left":
            consoleNet("net: " + event.name + " left");
            break;
        case "chat":
            consoleNet("net: " + (event.direct ? "dm " : "") +
                (event.from === netName ? "you" : event.from) + ": " + event.text);
            break;
        case "roster":
            netRoster = Array.isArray(event.names) ? event.names.slice() : [];
            consoleNet("net: roster " + netRoster.join(", "));
            break;
        case "notice":
            consoleNet("net: " + event.text);
            break;
        case "disconnected":
            netReset();
            consoleNet("net: disconnected");
            break;
        case "error":
            netReset();
            consoleNet("net: error " + event.text);
            break;
        default:
            consoleNet("net: unknown event " + String(line));
    }
}
