// Every word on the website lives in this file. Change the text here; the layout is in
// src/components. Keep it plain English: short sentences, everyday words, and only claims
// that are true of the app as it ships (the root README is the reference).

const repo = "https://github.com/arjunkambj/open-spaces";

export const links = {
  site: "https://whisper.0xhoney.com/",
  repo,
  /** A file with a fixed name that every release carries, so this address never changes. */
  download: `${repo}/releases/latest/download/Spaces.dmg`,
  releases: `${repo}/releases`,
  install: `${repo}#install`,
  buildIphone: `${repo}#iphone`,
  agentGuide: `${repo}/blob/main/docs/agents.md`,
  contributing: `${repo}/blob/main/CONTRIBUTING.md`,
  issues: `${repo}/issues/new/choose`,
  licence: `${repo}/blob/main/LICENSE`,
} as const;

export const site = {
  name: "Spaces",
  title: "Spaces: voice dictation and meeting notes for Mac",
  description:
    "Hold a key, speak, and clean text appears in the app you are typing in. Spaces is a free, open-source Mac app that also records meetings and writes the notes.",
  socialImageAlt: "The Spaces window on a Mac, showing a list of dictated sentences.",
} as const;

export const nav = [
  { label: "Meetings", href: "#meetings" },
  { label: "Agents", href: "#agents" },
  { label: "Privacy", href: "#privacy" },
  { label: "GitHub", href: links.repo },
] as const;

export const download = {
  button: "Download for Mac",
  shortButton: "Download",
  requirements: "macOS 14.4 or later · Apple silicon",
  firstLaunch: "The app is not signed by Apple, so macOS asks you to confirm the first time you open it.",
  firstLaunchLink: "See how",
} as const;

/** A word as it was heard. A filler is one the tidy-up step takes out. */
export interface SpokenWord {
  text: string;
  filler?: boolean;
}

export const hero = {
  headline: "Talk instead of typing.",
  lead: "Hold fn, speak, and let go. Spaces types clean text into whatever app you are using. It also records your meetings and writes the notes.",
  status: "Free and open source. An early version.",
  // The same sentence is in the Home picture below, so the two match.
  saidLabel: "You say",
  said: [
    { text: "um", filler: true },
    { text: "could" },
    { text: "we" },
    { text: "uh", filler: true },
    { text: "move" },
    { text: "the" },
    { text: "review" },
    { text: "to" },
    { text: "thursday" },
    { text: "at" },
    { text: "3" },
    { text: "pm" },
  ] satisfies SpokenWord[],
  typedLabel: "It types, in Mail",
  typed: "Could we move the review to Thursday at 3 pm?",
  pillLabel: "The Spaces pill while it listens: a small dark capsule with moving bars.",
  pictureAlt:
    "The Spaces window. A list of dictated sentences, each with the time and the app it was typed into.",
  pictureCaption: "Home keeps what you said, and where it went.",
} as const;

export interface Shortcut {
  keys: readonly string[];
  name: string;
  text: string;
}

export const shortcuts: {
  title: string;
  lead: string;
  items: readonly Shortcut[];
  extras: string;
} = {
  title: "One key, every app.",
  lead: "The default shortcuts. You can change each one in Settings.",
  items: [
    { keys: ["fn"], name: "Dictate", text: "Hold, speak, let go. The text lands where your cursor is." },
    { keys: ["fn", "Space"], name: "Hands-free", text: "Press once to start and again to stop. Good for long thoughts." },
    { keys: ["fn", "Control"], name: "Change selected text", text: "Select some text, hold, and say how. “Make this shorter.”" },
    { keys: ["Control", "Command", "V"], name: "Paste it again", text: "Types your last dictation once more." },
    { keys: ["Control", "Option", "M"], name: "Record a meeting", text: "Start or stop a recording from anywhere." },
  ],
  extras:
    "Teach it the names it gets wrong. Say a short phrase to get a longer snippet. Pick a writing style for each kind of app: formal in email, casual in chat.",
};

export const meetings = {
  title: "Record the meeting. Keep talking.",
  text: [
    "It records your microphone and what your Mac plays, so both sides of a call are there. Each line is marked Me or Others.",
    "When you stop, you get a summary, key points, decisions and action items. Ask a question later and the answer comes from that meeting.",
  ],
  crash: "If the app closes in the middle, the audio is kept and the meeting is finished the next time you open it.",
  pictureAlt:
    "A meeting in Spaces: a summary, key points, decisions and action items, with a box to ask questions.",
} as const;

export const agents = {
  title: "Your AI agent can read the notes too.",
  lead: "Spaces comes with a small tool called spaces. With it, an agent such as Claude Code, Cursor or Codex can read your meetings and notes and add to them. It speaks MCP, a common way for AI tools to use other programs.",
  setupLabel: "Set it up once. This is the line for Claude Code:",
  // Copied from docs/agents.md. Keep the two the same.
  command: 'claude mcp add --scope user open-spaces -- "/Applications/Spaces.app/Contents/MacOS/spaces" mcp',
  otherTools: "The lines for Claude Desktop, Cursor and Codex are in the guide, and in the app under Settings → Agents.",
  examplesLabel: "Then ask",
  // Each tool name is a real one from the tables in docs/agents.md.
  examples: [
    { ask: "What are my open action items?", tool: "actions_list" },
    { ask: "What did we decide about pricing in the Northwind call?", tool: "meetings_search" },
    { ask: "Start recording a meeting called Design review.", tool: "recording_start" },
  ],
  limits:
    "The tool works only with the files in your Spaces folder. It makes no network calls, cannot read your API key, and cannot type into another app.",
  caution: "What an agent reads goes to that agent's own AI provider. Connect only tools you trust with your meetings.",
  guideLink: "Read the agent guide",
} as const;

export const copy = {
  button: "Copy",
  done: "Copied",
} as const;

export const privacy = {
  title: "Where your words go",
  lead: "No account, no server of ours, no tracking. Here is everything that leaves your Mac, and where it goes.",
  columns: [
    {
      title: "Stays on your Mac",
      items: [
        "History, meetings, dictionary and settings, as plain files in one folder. Read them, back them up or delete them.",
        "Your OpenAI API key, in a private file only your account can open.",
      ],
    },
    {
      title: "Goes to OpenAI, or a server you choose",
      items: [
        "Your audio, and the text made from it.",
        "Your name, your dictionary words and the name of the app you are typing into, to get spelling and style right.",
        "In command mode, the text you selected. For meeting notes and questions, that meeting's title, transcript and notes.",
      ],
    },
    {
      title: "Goes to GitHub",
      items: [
        "About once a day, a check for a newer version. It carries the app's name and version, and none of your data.",
      ],
    },
  ],
  note: "Your key is sent only to the server it was saved for. What you send to OpenAI is covered by OpenAI's own data rules, and you pay OpenAI for what you use.",
  thisPage: "This page has no analytics and no cookies. Everything on it, its scripts included, comes from this site.",
} as const;

export const closing = {
  title: "Try it on your next email.",
  lead: "You need a Mac and your own OpenAI API key.",
  openSource:
    "Spaces is open source under the MIT licence. It is an early version, so some things will be rough. Bug reports, ideas and fixes are welcome.",
  links: [
    { label: "See the code", href: links.repo },
    { label: "How to contribute", href: links.contributing },
    { label: "Report a bug", href: links.issues },
  ],
  iphone: "There is an iPhone app in the same repository. It is not on the App Store.",
  iphoneLink: "Build it with Xcode",
} as const;

export const footer = {
  links: [
    { label: "GitHub", href: links.repo },
    { label: "Releases", href: links.releases },
    { label: "MIT licence", href: links.licence },
  ],
  independent:
    "Spaces is an independent project. It is not connected to OpenAI or to any other dictation app.",
  pictures: "All pictures show made-up sample data.",
} as const;

export const notFound = {
  title: "Page not found",
  text: "There is nothing at this address.",
  link: "Go to the home page",
} as const;
