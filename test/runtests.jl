using Test, StaticArrays, Colors

# push!(LOAD_PATH, "./src", "src")
using Solids
import Solids: _FIXED, Vec, Path, Point
import Solids: from_clipper, to_clipper

function test_from_to(T, x)
	return @test from_clipper(T, to_clipper(T, x)) == x
end

@testset "Types" begin #<<<1
@testset "Basic types" begin #<<<2
V = Point(1,2)
@test V.coords === SA[1,2]
end
@testset "Conversion to/from Clipper.jl" begin #<<<2
V = Point(1,2)
test_from_to(Int, 3)
test_from_to(Int, V)
test_from_to(Int, [V, V])
test_from_to(_FIXED, 3)
test_from_to(_FIXED, Point{2,_FIXED}(1,2))
test_from_to(Float64, 3)
end
end

@testset "Handling of objects" begin #<<<1
using Solids: Square, Circle
using Solids: children
using Solids: mult_matrix, translate, scale
using Solids: color
s = Square(1)
@testset "Primitives" begin #<<<2
@test s == Square([1,1])
end
@testset "Operations" begin #<<<2
@test union(s, union()) === s
@test length(children(union(s, union(s)))) == 2
end
@testset "Transforms" begin #<<<2
@test 2s == scale(2, s)
@test scale(2)*s == scale(2, s)
@test scale(2)*[s] == scale(2, s)
@test color("red", s) == color(parse(Colorant, "red"), s)
end
end
@testset "Clipper" begin #<<<1
s = Square(1)
# FIXME
end
@testset "Extrusion" begin #<<<1
using Solids: path_extrude, points
C = points(Circle(3.),(precision=.01,accuracy=1))
c = [Point(20*cos(i),20*sin(i)) for i in 0:.1:π]; c=[c;[Point(0.,-1.)]]
@test (path_extrude(c, C)) != 0
end
@testset "Convex hull" begin #<<<1
using Solids: convex_hull, convex_hull_list
P(x...) = Point(Float64.(x)...)
CH = convex_hull([P(0,0,0),P(0,0,10),P(10,0,0),P(0,10,0),P(1,1,1),P(1,0,0),])
@test Set(CH[1]) == Set([P(0,0,0),P(0,0,10),P(10,0,0),P(0,10,0),])
@test length(CH[2]) ==4
@test convex_hull_list([ P(0., 0), P(1., 1), P(-1., 1), P(.2, 2.), P(0, .8), P(-.2, .8), ]) == [1,2,4,3]
# @test convex_hull_list(Solids.rows(SA[0. 0;1. 1;-1. 1;.2 2.;0 .8;-.2 .8])) == [1,2,4,3]
@test convex_hull_list([
	P(-2.627798062316817, 1.075268817204301),
	P(-0.5030257403564974, -1.720430107526882),
	P(0.7927283156659947, 2.7956989247311825),
	P(0.0, 2.396978520135108),
	P(0.0, 0.03278003249806397),
	]) == [2,5,3,1]
@test convex_hull_list([
	P(-2.150537634408602, 1.3494700327417308),
	P(-0.4301075268817205, -2.097580910437773),
	P(2.3655913978494625, 0.04739817471346019),
	P(0.0, 0.0),
	P(2.3038140933536018, 0.0),
	P(0.0, 0.7294358146330306),
	])== [2,5,3,6,1]
end
@testset "Surfaces" begin #<<<1
using Solids: connected_components, Surface, merge, select_faces
using Solids: nvertices, nfaces
v=[[0,-1],[1,0],[0,1],[-1,0]]
for j in eachindex(v), i in 1:j-1
	@test Solids.circular_lt(v[i], v[j])
end
@test connected_components([:a, :b, :c, :d, :e], [[1,2],[1,3],[4,5]]) ==
	[([:a, :b, :c], [[1,2],[1,3]]),
	 ([:d, :e], [[1,2]]) ]
function pyramid(t=[0,0,0], n=0)
	points = Solids.Point{3}.([ t, t+[2.,0,0], t+[2,2,0], t+[0,2,0], t+[1,1,1]])
	faces = [[4,3,2],[2,3,1],[1,2,5],[2,3,5],[3,4,5],[4,1,5]]
	faces1 = [ f .+ n for f in faces ]
	return Surface(points, faces1)
end
p1 = pyramid()
p2 = pyramid([1,0,0])
p3 = merge(p1, p2)
p1bis = select_faces(1:6, p3)
@test nfaces(p1bis) == nfaces(p1)
@test nvertices(p1bis) == nvertices(p1)
u12 = union(p1, p2)
i12 = intersect(p1, p2)
@test length(u12.points) == 14 && length(u12.faces) == 24
@test length(i12.points) == 8  && length(u12.faces) == 12
end
#>>>1

# vim: noet ts=2 fmr=<<<,>>>

