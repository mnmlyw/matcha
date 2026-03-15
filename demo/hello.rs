// Matcha syntax highlighting demo — Rust

use std::collections::HashMap;
use std::fmt;

const MAX_SIZE: usize = 256;
static GREETING: &str = "Hello from Matcha!";

#[derive(Debug, Clone)]
struct Point {
    x: f64,
    y: f64,
}

impl Point {
    fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }

    fn distance(&self, other: &Point) -> f64 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        (dx * dx + dy * dy).sqrt()
    }
}

impl fmt::Display for Point {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

#[derive(Debug)]
enum Shape {
    Circle { center: Point, radius: f64 },
    Rectangle { origin: Point, width: f64, height: f64 },
}

impl Shape {
    fn area(&self) -> f64 {
        match self {
            Shape::Circle { radius, .. } => std::f64::consts::PI * radius * radius,
            Shape::Rectangle { width, height, .. } => width * height,
        }
    }
}

fn fibonacci(n: u32) -> Vec<u64> {
    let mut fibs = vec![0u64, 1];
    for i in 2..n as usize {
        let next = fibs[i - 1] + fibs[i - 2];
        fibs.push(next);
    }
    fibs
}

fn main() {
    println!("{}", GREETING);

    let origin = Point::new(0.0, 0.0);
    let p = Point::new(3.0, 4.0);
    println!("Distance: {:.2}", origin.distance(&p));

    // Shapes
    let shapes: Vec<Shape> = vec![
        Shape::Circle { center: origin.clone(), radius: 5.0 },
        Shape::Rectangle { origin: origin.clone(), width: 10.0, height: 20.0 },
    ];

    for shape in &shapes {
        println!("{:?} -> area = {:.2}", shape, shape.area());
    }

    // HashMap
    let mut scores: HashMap<&str, i32> = HashMap::new();
    scores.insert("Alice", 95);
    scores.insert("Bob", 87);

    if let Some(&score) = scores.get("Alice") {
        println!("Alice scored {}", score);
    }

    let fibs = fibonacci(10);
    let sum: u64 = fibs.iter().sum();
    println!("Fibonacci sum: {}", sum);
}
