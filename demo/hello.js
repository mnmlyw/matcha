// Matcha syntax highlighting demo — JavaScript/TypeScript

const APP_NAME = "Matcha";
const VERSION = 0x01;
const TAU = 6.283185;

/**
 * A simple task manager class.
 * Demonstrates block comments spanning multiple lines.
 */
class TaskManager {
    #tasks = [];

    constructor(owner) {
        this.owner = owner;
        this.createdAt = new Date();
    }

    addTask(title, priority = "medium") {
        const task = {
            id: this.#tasks.length + 1,
            title,
            priority,
            done: false,
        };
        this.#tasks.push(task);
        return task;
    }

    complete(id) {
        const task = this.#tasks.find((t) => t.id === id);
        if (task) {
            task.done = true;
        }
        return task;
    }

    get pending() {
        return this.#tasks.filter((t) => !t.done);
    }

    summary() {
        const total = this.#tasks.length;
        const done = this.#tasks.filter((t) => t.done).length;
        return `${this.owner}: ${done}/${total} tasks complete`;
    }
}

// Async function with template literals
async function fetchData(url) {
    try {
        const response = await fetch(url);
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const data = await response.json();
        return data;
    } catch (err) {
        console.error(`Failed to fetch: ${err.message}`);
        return null;
    }
}

// Destructuring + arrow functions
const numbers = [1, 2, 3, 4, 5];
const doubled = numbers.map((n) => n * 2);
const [first, ...rest] = doubled;

console.log(`${APP_NAME} v${VERSION}`);
console.log(`First: ${first}, Rest: ${rest}`);
