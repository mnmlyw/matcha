"""
Matcha syntax highlighting demo — Python edition.
This is a multi-line docstring.
"""

import os
from pathlib import Path

# Constants
MAX_RETRIES = 3
API_URL = "https://api.example.com"
HEX_VALUE = 0xFF
BINARY = 0b1010

class Animal:
    """Represents an animal with a name and sound."""

    def __init__(self, name: str, sound: str):
        self.name = name
        self.sound = sound
        self._energy = 100

    def speak(self) -> str:
        return f"{self.name} says {self.sound}!"

    @property
    def is_tired(self) -> bool:
        return self._energy < 20

    def rest(self):
        self._energy = min(self._energy + 30, 100)


def fibonacci(n: int) -> list[int]:
    """Generate the first n Fibonacci numbers."""
    if n <= 0:
        return []
    elif n == 1:
        return [0]

    result = [0, 1]
    for i in range(2, n):
        result.append(result[i - 1] + result[i - 2])
    return result


def main():
    # Create some animals
    cat = Animal("Cat", "meow")
    dog = Animal("Dog", "woof")

    for animal in [cat, dog]:
        print(animal.speak())

    # Fibonacci
    fibs = fibonacci(10)
    total = sum(fibs)
    print(f"First 10 Fibonacci numbers: {fibs}")
    print(f"Sum: {total}")

    # Dictionary comprehension
    squares = {x: x ** 2 for x in range(10)}
    evens = [v for k, v in squares.items() if k % 2 == 0]
    print(f"Even squares: {evens}")

    try:
        value = 42 / 0
    except ZeroDivisionError as e:
        print(f"Caught error: {e}")
    finally:
        print("Done!")


if __name__ == "__main__":
    main()
