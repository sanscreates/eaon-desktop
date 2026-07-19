// Real quotes from tech pioneers, shown once per launch on the welcome
// banner. Every entry here was checked against multiple independent
// sources before inclusion — several plausible, extremely widely-quoted
// candidates were DROPPED after checking turned up that they predate their
// commonly-credited speaker (e.g. "a ship in port is safe" is John Shedd's,
// 1928 — Grace Hopper popularized it but didn't coin it; "ask forgiveness,
// not permission" is older than her too). Better to ship fewer, correctly
// attributed quotes than a longer list with a wrong name on one of them.

export interface Quote {
  text: string;
  author: string;
}

export const QUOTES: Quote[] = [
  { text: "The most dangerous phrase in the language is, 'We've always done it this way.'", author: "Grace Hopper" },
  { text: "I visualize a time when we will be to robots what dogs are to humans, and I'm rooting for the machines.", author: "Claude Shannon" },
  { text: "We can only see a short distance ahead, but we can see plenty there that needs to be done.", author: "Alan Turing" },
  { text: "The best way to predict the future is to invent it.", author: "Alan Kay" },
  { text: "Premature optimization is the root of all evil.", author: "Donald Knuth" },
  { text: "The question of whether a computer can think is no more interesting than the question of whether a submarine can swim.", author: "Edsger Dijkstra" },
  { text: "Talk is cheap. Show me the code.", author: "Linus Torvalds" },
  { text: "UNIX is basically a simple operating system, but you have to be a genius to understand the simplicity.", author: "Dennis Ritchie" },
  { text: "One of my most productive days was throwing away 1,000 lines of code.", author: "Ken Thompson" },
  { text: "This is for everyone.", author: "Tim Berners-Lee" },
  { text: "The more you buy, the more you save.", author: "Jensen Huang" },
  { text: "There was no second chance. We knew that.", author: "Margaret Hamilton" },
  { text: "Girls are capable of doing everything men are capable of doing. Sometimes they have more imagination than men.", author: "Katherine Johnson" },
  { text: "The Analytical Engine has no pretensions whatever to originate anything. It can do whatever we know how to order it to perform.", author: "Ada Lovelace" },
];

export function pickRandomQuote(): Quote {
  return QUOTES[Math.floor(Math.random() * QUOTES.length)];
}
