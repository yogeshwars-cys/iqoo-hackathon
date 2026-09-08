/**
 * The narration script — single source of truth.
 *
 * Drives the on-screen captions AND doubles as the voiceover timing sheet
 * (see script/narration.md, which is generated from these same numbers).
 * `t` and `d` are seconds relative to the start of each 60-second scene.
 *
 * ~750 words total, paced at ~150 wpm. Every scene is deliberately left with
 * a few seconds of headroom at the end so a human read can run long without
 * colliding with the next scene.
 */

export type Line = {t: number; d: number; text: string};

export type Scene = {
  id: string;
  chapter: string;
  title: string;
  lines: Line[];
};

export const SCENES: Scene[] = [
  {
    id: 'problem',
    chapter: 'ONE',
    title: 'The Problem',
    lines: [
      {t: 0.5, d: 4.0, text: 'To use AI on your own documents, you are asked to upload them.'},
      {t: 4.7, d: 4.5, text: "Contracts. Medical records. Source code. Research you haven't published yet."},
      {t: 9.4, d: 4.2, text: 'The moment they leave your machine, you lose control of the copy.'},
      {t: 13.8, d: 4.0, text: 'Retained. Indexed. Subpoenaed. Sometimes trained on.'},
      {t: 18.0, d: 5.2, text: "Encryption in transit doesn't help — the server must read the plaintext to embed it."},
      {t: 23.4, d: 3.2, text: 'So you try running it locally instead.'},
      {t: 26.8, d: 4.6, text: 'Now a transformer is competing with your compiler for the same cores.'},
      {t: 31.6, d: 4.4, text: 'The laptop heats up, the fans spin, and the whole machine throttles.'},
      {t: 36.2, d: 4.6, text: 'Meanwhile the most capable idle processor you own is in your pocket.'},
      {t: 41.0, d: 5.4, text: 'Phones ship neural accelerators rated in tens of trillions of operations per second.'},
      {t: 46.6, d: 4.0, text: 'They sit near zero utilisation while you work.'},
      {t: 51.0, d: 2.4, text: 'Two problems, one shape:'},
      {t: 53.6, d: 5.0, text: 'the data is in the wrong place, and the work is on the wrong processor.'},
    ],
  },
  {
    id: 'solution',
    chapter: 'TWO',
    title: 'How It Is Solved',
    lines: [
      {t: 0.5, d: 3.2, text: 'The fix is to invert the topology.'},
      {t: 4.0, d: 4.0, text: 'Stop treating the phone as a thin client for the cloud.'},
      {t: 8.2, d: 5.0, text: 'Treat it as a private inference appliance that happens to fit in your pocket.'},
      {t: 13.4, d: 4.4, text: 'Your documents are ingested once, on the device, and never leave it.'},
      {t: 18.0, d: 4.0, text: 'The phone holds the corpus, the index, and the encoder.'},
      {t: 22.2, d: 4.6, text: 'The laptop keeps what it is actually good at: writing and reasoning.'},
      {t: 27.0, d: 4.0, text: 'When you ask a question, only the question crosses the gap.'},
      {t: 31.2, d: 5.0, text: 'The vault embeds it, searches its own index, and returns a handful of passages.'},
      {t: 36.4, d: 4.4, text: 'Retrieval is private. Generation happens wherever you choose.'},
      {t: 41.0, d: 2.8, text: 'That separation is the whole idea.'},
      {t: 44.0, d: 3.4, text: 'A gigabyte of private material stays put.'},
      {t: 47.6, d: 4.4, text: 'A few hundred tokens of relevant context is all that moves.'},
      {t: 52.2, d: 4.6, text: 'And it moves over a direct device-to-device link, not the internet.'},
    ],
  },
  {
    id: 'implementation',
    chapter: 'THREE',
    title: 'How It Is Built',
    lines: [
      {t: 0.5, d: 2.8, text: 'Concretely, here is the pipeline.'},
      {t: 3.5, d: 4.6, text: 'Ingestion extracts plain text from documents, code, and captured images.'},
      {t: 8.1, d: 4.8, text: 'A chunker splits it into overlapping windows of roughly 256 tokens,'},
      {t: 13.1, d: 4.4, text: 'overlapped so an idea spanning a boundary is never cut in half.'},
      {t: 17.7, d: 5.0, text: 'Each chunk goes through a sentence encoder — MiniLM, 384 dimensions,'},
      {t: 22.9, d: 4.8, text: "quantised and compiled for the phone's neural engine through the vendor delegate."},
      {t: 27.9, d: 4.6, text: 'The vectors land in a local SQLite database with a vector index,'},
      {t: 32.7, d: 4.4, text: 'encrypted at rest with a key held in hardware-backed storage.'},
      {t: 37.3, d: 3.6, text: 'At query time the same encoder embeds the question,'},
      {t: 41.1, d: 4.4, text: 'cosine similarity ranks the index, and the top passages are serialised.'},
      {t: 45.7, d: 4.2, text: 'The cross-device bridge carries them to an editor extension,'},
      {t: 50.1, d: 3.8, text: 'which assembles the prompt for whichever model you trust.'},
      {t: 54.1, d: 4.6, text: 'And the application requests no network permission at all.'},
    ],
  },
  {
    id: 'novelty',
    chapter: 'FOUR',
    title: 'What Is New',
    lines: [
      {t: 0.5, d: 2.8, text: 'So what is actually new here?'},
      {t: 3.5, d: 2.6, text: 'First: the direction of trust.'},
      {t: 6.3, d: 4.0, text: 'Normally the small device asks the big one for help.'},
      {t: 10.5, d: 5.2, text: 'Here the personal device is the trusted core, and the workstation is the edge.'},
      {t: 16.0, d: 3.8, text: 'Second: privacy is enforced, not promised.'},
      {t: 20.0, d: 4.6, text: 'A missing permission is a property an auditor can verify in seconds.'},
      {t: 24.8, d: 4.4, text: "It does not rest on a policy document or a vendor's good behaviour."},
      {t: 29.4, d: 2.8, text: 'Third: minimal disclosure.'},
      {t: 32.4, d: 4.4, text: 'Even the side you trust only ever sees the passages it needs,'},
      {t: 37.0, d: 2.0, text: 'never the corpus.'},
      {t: 39.2, d: 4.6, text: 'Fourth: it runs on silicon you already own and are not using.'},
      {t: 44.0, d: 4.2, text: 'No new hardware, no per-token cost, no rate limit.'},
      {t: 48.4, d: 4.0, text: 'And because capture is local, a photograph of a whiteboard'},
      {t: 52.6, d: 4.4, text: 'becomes searchable knowledge without ever touching a server.'},
    ],
  },
  {
    id: 'future',
    chapter: 'FIVE',
    title: 'Where It Goes',
    lines: [
      {t: 0.5, d: 2.4, text: 'Where this goes next.'},
      {t: 3.1, d: 3.8, text: 'In the near term, generation moves on-device too.'},
      {t: 7.1, d: 3.4, text: 'A small language model reads the retrieved passages,'},
      {t: 10.7, d: 3.4, text: 'and the loop closes entirely inside the vault.'},
      {t: 14.3, d: 2.8, text: 'After that, vaults federate.'},
      {t: 17.3, d: 5.2, text: 'Phone, laptop, workstation — one personal index, synchronised directly,'},
      {t: 22.7, d: 3.8, text: 'peer to peer, with no server in the middle.'},
      {t: 26.7, d: 2.8, text: 'Then ingestion becomes ambient.'},
      {t: 29.7, d: 5.2, text: 'Meetings, screenshots, notes — indexed continuously, locally, never uploaded.'},
      {t: 34.9, d: 4.8, text: 'The longer arc is about where personal AI should live by default.'},
      {t: 39.9, d: 4.8, text: 'Every year more neural silicon ships inside devices people already carry.'},
      {t: 44.9, d: 4.4, text: 'The data is already there. The compute is already there.'},
      {t: 49.5, d: 5.0, text: 'The only thing still missing is the assumption that it has to leave.'},
      {t: 54.7, d: 3.6, text: 'Build the vault. Keep the corpus.'},
    ],
  },
];

/** Total spoken words, for pacing checks. */
export const WORD_COUNT = SCENES.reduce(
  (n, s) => n + s.lines.reduce((m, l) => m + l.text.split(/\s+/).length, 0),
  0,
);
