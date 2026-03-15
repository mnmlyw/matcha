// Matcha syntax highlighting demo — Go

package main

import (
	"fmt"
	"math"
	"strings"
)

const maxRetries = 3
const version = "0.1.0"

// Point represents a 2D coordinate.
type Point struct {
	X float64
	Y float64
}

func (p Point) Distance(other Point) float64 {
	dx := p.X - other.X
	dy := p.Y - other.Y
	return math.Sqrt(dx*dx + dy*dy)
}

func (p Point) String() string {
	return fmt.Sprintf("(%g, %g)", p.X, p.Y)
}

// Shape is implemented by geometric types.
type Shape interface {
	Area() float64
	Perimeter() float64
}

type Circle struct {
	Center Point
	Radius float64
}

func (c Circle) Area() float64 {
	return math.Pi * c.Radius * c.Radius
}

func (c Circle) Perimeter() float64 {
	return 2 * math.Pi * c.Radius
}

type Rectangle struct {
	Origin Point
	Width  float64
	Height float64
}

func (r Rectangle) Area() float64 {
	return r.Width * r.Height
}

func (r Rectangle) Perimeter() float64 {
	return 2 * (r.Width + r.Height)
}

func fibonacci(n int) []int {
	if n <= 0 {
		return nil
	}
	fibs := make([]int, n)
	fibs[0] = 0
	if n > 1 {
		fibs[1] = 1
		for i := 2; i < n; i++ {
			fibs[i] = fibs[i-1] + fibs[i-2]
		}
	}
	return fibs
}

func main() {
	fmt.Printf("Matcha demo v%s\n", version)

	origin := Point{0, 0}
	p := Point{3, 4}
	fmt.Printf("Distance from %s to %s: %.2f\n", origin, p, origin.Distance(p))

	/* Multi-line block comment:
	   This demonstrates that block comments
	   are highlighted correctly across lines. */
	shapes := []Shape{
		Circle{Center: origin, Radius: 5},
		Rectangle{Origin: origin, Width: 10, Height: 20},
	}

	for _, shape := range shapes {
		fmt.Printf("Area: %.2f, Perimeter: %.2f\n", shape.Area(), shape.Perimeter())
	}

	fibs := fibonacci(10)
	parts := make([]string, len(fibs))
	for i, v := range fibs {
		parts[i] = fmt.Sprintf("%d", v)
	}
	fmt.Printf("Fibonacci: [%s]\n", strings.Join(parts, ", "))
}
