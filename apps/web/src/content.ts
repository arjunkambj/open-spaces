// Every word on the website lives in this file. Change the text here; the layout is in
// src/components. Keep it plain English: short sentences, everyday words, and only claims
// that are true of the app as it ships (the root README is the reference).

const repo = "https://github.com/arjunkambj/open-wisper";

export const links = {
  site: "https://whisper.0xhoney.com/",
  repo,
  /** A file with a fixed name that every release carries, so this address never changes. */
  download: `${repo}/releases/latest/download/Open-Wisper.dmg`,
  releases: `${repo}/releases`,
  install: `${repo}#install`,
  buildIphone: `${repo}#iphone`,
  agentGuide: `${repo}/blob/main/docs/agents.md`,
  dataFormat: `${repo}/blob/main/docs/data-format.md`,
  contributing: `${repo}/blob/main/CONTRIBUTING.md`,
  issues: `${repo}/issues/new/choose`,
  licence: `${repo}/blob/main/LICENSE`,
} as const;

export const site = {
  name: "Open Wisper",
  title: "Open Wisper: voice dictation and meeting notes for Mac",
  description:
    "Hold a key, speak, and clean text appears in the app you are typing in. Open Wisper is a free, open-source Mac app that also records meetings and writes the notes.",
  socialImageAlt: "The Open Wisper window on a Mac, showing a list of dictated sentences.",
} as const;

export const nav = [
  { label: "Features", href: "#features" },
  { label: "Agents", href: "#agents" },
  { label: "Privacy", href: "#privacy" },
] as const;

export const download = {
  button: "Download for Mac",
  shortButton: "Download",
  requirements: "macOS 14.4 or later · Apple silicon",
  firstLaunch:
    "The app is not signed with an Apple Developer ID, so macOS asks you to confirm the first time you open it.",
  firstLaunchLink: "See the steps",
} as const;

export const hero = {
  headline: "Talk instead of typing.",
  lead: "Hold a key, speak, and clean text appears in whatever app you are using. Open Wisper also records your meetings and writes the notes.",
  github: "View on GitHub",
  pictureAlt:
    "The Open Wisper window. A list of dictated sentences, each with the time and the app it was typed into.",
  pillLabel: "The small pill at the bottom of the screen, showing that Open Wisper is listening.",
  status: "Free and open source · An early version",
} as const;

export const steps = {
  title: "How it works",
  items: [
    {
      title: "Hold a key and speak",
      text: "Hold fn and talk. Let go when you are done. Your Mac records the audio.",
    },
    {
      title: "Your voice becomes text",
      text: "The audio goes to OpenAI with your own API key. A second quick step takes out the ums and fixes the punctuation.",
    },
    {
      title: "The text lands where you type",
      text: "The words are typed into the app you are using: an email, a chat, a document.",
    },
  ],
} as const;

export interface Feature {
  title: string;
  text: string;
  /** The default keys for it, shown as key caps. */
  keys?: readonly string[];
}

export const dictation: { title: string; lead: string; items: readonly Feature[] } = {
  title: "Dictation, in every app",
  lead: "One shortcut, and your voice works anywhere you can type.",
  items: [
    {
      title: "Dictate anywhere",
      text: "Hold a key, talk, let go. The text is typed into the app you are using.",
      keys: ["fn"],
    },
    {
      title: "Hands-free mode",
      text: "Press once to start and once to stop. Good for long thoughts.",
      keys: ["fn", "Space"],
    },
    {
      title: "Command mode",
      text: "Select some text, hold the keys, and say how to change it. “Make this shorter.”",
      keys: ["fn", "Control"],
    },
    {
      title: "Dictionary and snippets",
      text: "Teach it the names it gets wrong. Say a short phrase and get a longer piece of text.",
    },
    {
      title: "A writing style for each kind of app",
      text: "Formal in email, casual in chat. You choose.",
    },
    {
      title: "The floating pill",
      text: "A small pill at the bottom of the screen shows when Open Wisper is listening. Click it to dictate.",
    },
  ],
};

export const meetings = {
  title: "Meetings, with the notes written for you",
  lead: "Press record and get on with the meeting.",
  items: [
    {
      title: "Both sides of a call",
      text: "It records your microphone and what your Mac plays. The transcript marks each line “Me” or “Others”.",
    },
    {
      title: "Notes and action items",
      text: "When the meeting ends you get a summary, key points, decisions and action items.",
    },
    {
      title: "Ask about a meeting",
      text: "Ask a question and get an answer from that meeting's transcript and notes.",
    },
  ],
  pictureAlt:
    "A meeting in Open Wisper: a summary, key points, decisions and action items, with a box to ask questions.",
} as const;

export const agents = {
  title: "Works with your AI agent",
  lead: "Open Wisper comes with a small tool called wisper. With it, an AI agent such as Claude Code, Cursor or Codex can read your meetings and notes and add to them.",
  mcp: "It works with any tool that speaks MCP, a common way for AI tools to use other programs. It is also a normal command for the terminal.",
  setupLabel: "Set it up once. This is the line for Claude Code:",
  // Copied from docs/agents.md. Keep the two the same.
  command: 'claude mcp add --scope user open-wisper -- "/Applications/Open Wisper.app/Contents/MacOS/wisper" mcp',
  otherTools: "The lines for Claude Desktop, Cursor and Codex are in the guide, and in the app under Settings → Agents.",
  examplesLabel: "Then ask",
  toolLabel: "Tool it uses",
  // Each tool name is a real one from the tables in docs/agents.md.
  examples: [
    { ask: "What are my open action items?", tool: "actions_list" },
    { ask: "What did we decide about pricing in the Northwind call?", tool: "meetings_search" },
    { ask: "Add a note to today's standup: Sam confirmed the migration is done.", tool: "meetings_add_note" },
    { ask: "Start recording a meeting called Design review.", tool: "recording_start" },
  ],
  limitsTitle: "Kept on a short lead",
  limits: [
    "The tool works only with the files in your Open Wisper folder.",
    "It makes no network calls and cannot read your API key.",
    "It cannot change your settings, start dictation or type into another app.",
  ],
  caution:
    "What an agent reads goes to that agent's own AI provider. Connect only tools you trust with your meetings.",
  guideLink: "Read the agent guide",
} as const;

export const privacy = {
  title: "Private by design",
  lead: "No account, no server of ours, no tracking. Your files stay on your Mac.",
  items: [
    {
      title: "Plain files on your Mac",
      text: "History, meetings, dictionary and settings are JSON, Markdown and audio files in one folder. You can read them, back them up or delete them.",
    },
    {
      title: "Your key in the Keychain",
      text: "Your OpenAI API key is kept where your Mac keeps passwords. It is sent only to the server it was saved for.",
    },
    {
      title: "No account, no tracking",
      text: "There is nothing to sign up for. We run no server, so we never see your audio, your text or your key.",
    },
    {
      title: "Your own server, if you like",
      text: "Point it at any server that works like OpenAI's, such as a proxy or a model running on your own machine.",
    },
  ],
  sentTitle: "What leaves your Mac",
  sent: [
    "Your audio, and the text made from it.",
    "To get spelling and style right: your name, your dictionary words and the name of the app you are typing into.",
    "In command mode, the text you selected.",
    "For meeting notes and questions: that meeting's title, transcript and notes.",
  ],
  sentWhere:
    "All of it goes only to OpenAI, or to the server you chose instead. What you send to OpenAI is covered by OpenAI's own data rules, and you pay OpenAI for what you use.",
  updates:
    "One more request: about once a day the app asks GitHub whether there is a newer version. It carries the app's name and version, and none of your data.",
  thisPage: "This page has no analytics, no cookies and no scripts, and loads nothing from other sites.",
} as const;

export const openSource = {
  title: "Open source, MIT licence",
  lead: "All of the code is on GitHub. Use it, change it, share it, sell what you make with it. Do anything you like with it.",
  help: "This is an early version, and some things will be rough. Help is welcome: bug reports, ideas, fixes and features.",
  links: [
    { label: "See the code", href: links.repo },
    { label: "How to contribute", href: links.contributing },
    { label: "Report a bug", href: links.issues },
  ],
  iphone: "There is an iPhone app in the same repository. It is not on the App Store.",
  iphoneLink: "Build it with Xcode",
} as const;

export const closing = {
  title: "Try Open Wisper",
  lead: "You need a Mac and your own OpenAI API key.",
} as const;

export const footer = {
  links: [
    { label: "GitHub", href: links.repo },
    { label: "Releases", href: links.releases },
    { label: "MIT licence", href: links.licence },
  ],
  independent:
    "Open Wisper is an independent project. It is not connected to OpenAI or to any other dictation app.",
  pictures: "All pictures show made-up sample data.",
} as const;

export const notFound = {
  title: "Page not found",
  text: "There is nothing at this address.",
  link: "Go to the home page",
} as const;
