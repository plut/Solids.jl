module Solids
# BUG: SA[1 2; 3 4]*HybridArray{Tuple{2,StaticArrays.Dynamic()}}[1 2; 3 4]
# is a (dynamic) Matrix
#

# using Printf
using LinearAlgebra
using StaticArrays
using FixedPointNumbers
using SparseArrays
using Dictionaries

import GeometryBasics
import GeometryBasics: AbstractGeometry, Point, Vec
import GeometryBasics: HyperSphere, Sphere, Circle, Rect, Triangle
import GeometryBasics: AbstractMesh
@inline coordtype(::AbstractGeometry{N,T}) where{N,T} = T

import Polyhedra # for convex hull
import GLPK
# hide the Triangle module name so that we may use it for a type:
module LibTriangle
	import Triangle
	import Triangle: basic_triangulation
	function constrained_triangulation(args...)
		# XXX temporary: the libtriangle call tends to segfault whenever lines
		# cross, so we show what it is called with
		println("constrained triangulation: ", args...)
		return Triangle.constrained_triangulation(args...)
	end
end; import .LibTriangle
# using MiniQhull
import Rotations
import Colors
import Clipper
import LightGraphs

import Base: show, print
import Base: length, getindex, size, iterate, keys, eltype, convert
import Base: union, intersect, setdiff, copy, isempty
import Base: *, +, -, ∈, inv, sign, iszero

#————————————————————— Ideal objects —————————————————————————————— ««1
#»»1
# Types««1
# Numeric types ««2

"""
    Solids._FIXED
The type used whenever a fixed-precision real number is needed (e.g.
when interfacing with `Clipper.jl`).
"""
const _FIXED = Fixed{Int64,16}
"""
    Solids._REAL

The default type used for computing coordinates (i.e. the type to which
integers are converted). Defaults to a `Fixed` type (fixed-precision
real), but this module should work just as well with floats.
"""
# const _REAL = _FIXED
const _REAL = Float64
"""
    real_type(T)

The type of real numbers to which objects of type `T` are promoted.
"""
@inline real_type(T::Type{<:Real}) = T
@inline real_type(::Type{<:Integer}) = _REAL
@inline real_type(a::Type{<:Real}, b::Type{<:Real}...) =
	real_type(promote_type(a, b...))
@inline real_type(a::Real...) = real_type(typeof.(a)...)
@inline to_real(x::T) where{T} = convert(real_type(T), x)

# divide by two without losing type information
@inline one_half(x::Real) = x/2
@inline one_half(x::T) where{T<:Fixed} = reinterpret(T, reinterpret(x)>>1)
@inline one_half(x::Integer=1) = one_half(to_real(x))
@inline one_half(x::AbstractArray) = one_half.(x)

# by default, sqrt(::Fixed) is a Float. We do not want this.
# This is (disappointingly...) faster than implementing a custom
# integer square-root function:
@inline Base.sqrt(a::T) where{T<:FixedPoint} = T(Base.sqrt(Float64(a)))
@inline Base.rem2pi(a::T, r) where{T<:FixedPoint} =
	T(Base.rem2pi(Float64(a), r))

# Array indices ««2
"""
    cyclindex(i, a, [count=1])

Returns the index following `i` in the indices of array `a`, looping past
the end of `a` if needed.
If `count` is provided, advance by `count` steps instead.
"""
@inline cyclindex(i::Int, a) = _cyclindex(i, eachindex(a))
@inline _cyclindex(i::Int, a::Base.OneTo) = mod(i, a.stop)+1
@inline _cyclindex(i::Int, a::Base.OneTo, count::Int) =
	mod1(i+count, a.stop)

# Static vectors and paths««2
# Make point - point = vector
Base.:-(p::Point, q::Point) = Vec(p.data .- q.data)
@inline function barycenter(points::Point...)
	T = promote_type(eltype.(points)...)
	return Point(sum(points) / convert(real_type(T), length(points)))
end
# """
#     Vec{D,T}
# The type used for representing `D`-dimensional vectors (or points) with
# coordinates of type `T`. An alias for `SVector{D,T}`.
# """
# const Vec{D,T} = SVector{D,T} # type alias
# this comes with the following constructors:
# Vec{2}(SA[1,2])		Vec(SA[1,2])
# Vec{2}((1,2))			Vec((1,2))
# Vec{2}(1,2)				Vec(1,2)
# Vec{2}([1,2])			- (needs explicit size) -

# XXX: we might need an “embedding” function (maybe not a constructor though):
# Vec{3,T}(x::AnyVec{2,T}, fill = zero(T)) where{T} = 
#		Vec{3,T}(get(x, i, fill) for i in 1:3)
#
# we need to extend get to tuples for the next function.
# this will fail if wrong index, as intended.
# Base.get(t::NTuple{D,T}, i, fill) where{D,T} = t[i]
# Vec{D,T}(v::AnyVec{D,T}, fill = zero(T)) where{D,T} =
#		Vec{D,T}(get(v, i, fill) for i in 1:D)

# for the path type, three possibilities:
#  (1) HybridArray{Tuple{D,StaticArrays.Dynamic()}, T}
#  (2) Vector{SVector{D,T}}
#  (3) a trivial wrapper for (1) or (2)
#
# (3) is probably lots of code for nothing (unless we someday need to
# distinguish between different possible uses for a Vector{SVector{D,T}},
# which is possible). (1) would be nice, except for the oversight in
# HybridArrays that makes a matrix product (SMatrix * HybridMatrix) a
# (fully-dynamic) Matrix. So we went for (2).
#
# XXX We might someday need a path type which uses something else than
# Vector (e.g. a generator, for computed paths).

const Path{D,T<:Real} = Vector{Point{D,T}}
# the following functions are wrappers, which should allow us to
# rewrite `Path` objects as matrices instead (instead of `length` and
# `getindex`, return one matrix dimension and one column:)
# See also `apply` below.
@inline count(v::Path) = length(v)
@inline point(v::Path, i::Integer) = v[i]
@inline vertices(v::Path) = v

# This represents plausible user input for a `Path` object:
const AnyList{T} = Union{AbstractVector{<:T},NTuple{N,<:T} where{N}}
const AnyPath{D,T<:Real} = AnyList{<:Point{D,T}}

# @inline Base.convert(::Type{Path{D,T}}, v::AnyPath) where{D,T} =
# 	[Vec{D,T}(x) for x in v]
# @inline (::Type{<:Path{D}})(v::AnyPath{D,T}, fill=zero(T)) where{D,T} =
# 	[Vec{D,T}(x) for x in v]

# Path{D,T} = HybridArray{Tuple{D,StaticArrays.Dynamic()}, T}
# @inline count(v::Path) = size(v, 2)
# @inline point(v::Path, i::Integer) = v[:,i]
# Path{D,T}(v::AnyPath{D,T}, fill = zero(T)) where{D,T} =
#		Path{D,T}([p[i] for i in 1:D, p in v])

# const Paths{T} = AbstractVector{<:Path{T}}

@inline norm2(v::AbstractVector) = v ⋅ v

# Angle types««2
# to keep it simple, angles are just Float64 (in degrees).
# Just in case we might change this in the future, we define two types:
# Angle and AnyAngle (= input type).
const Angle = Float64
const AnyAngle = Real
const ° = 1.
@inline radians(x::Angle) = π/180*x
@inline radians(x::AnyAngle) = radians(Angle(x))
@inline degrees(x::Angle) = x
@inline degrees(x::AnyAngle) = degrees(Angle(x))

# General tools««1
# findextrema««2
"""
    findextrema(itr; lt=isless)

Like `findmin`, except that
 - it returns both extrema, as a `NamedTuple`;
 - it accepts an `lt` parameter, like `sort`.
"""
function findextrema(itr; lt=isless)
  p = pairs(itr); y = iterate(p)
  if y == nothing
    throw(ArgumentError("collection must be non-empty"))
  end
  (mi, m), s = y; (Mi, M) = (mi, m); i = mi
  while true
    y = iterate(p, s)
    y == nothing && break
    (ai, a), s = y
    if lt(a, m) m = a; mi = ai; end
    if lt(M, a) M = a; Mi = ai; end
  end
  return (min=(m, mi), max=(M, Mi))
end

# small determinants««2

# 2-dimensional determinant, useful for computing orientation
@inline det2(v1, v2) = v1[1]*v2[2] - v1[2]*v2[1]
@inline det2(pt1, pt2, pt3) = det2(pt2-pt1, pt3-pt1)

# 3-dimensional determinant
@inline det3(v1::Vec{3}, v2::Vec{3}, v3::Vec{3}) = det([v1 v2 v3])
@inline det3(p1::Point{3}, p2::Point{3}, p3::Point{3}, p4::Point{3}) =
	det3(p2-p1, p3-p1, p4-p1)
# @inline det3(v1, v2, v3) = det([v1 v2 v3])
# @inline det3(p1, p2, p3, p4) = det3(p2-p1, p3-p1, p4-p1)
# Geometry ««1
# the Geometry type««2
# """
# 		Geometry{D,T}
# 
# Abstract supertype for all solids.
# `D` is the dimension and `T` the type used for coordinates.
# A `Geometry{D,T}` object may contain, as children,
# objects with other coordinate types;
# such coordinates will be converted to type `T` when rendering.
# """
# abstract type Geometry{D,T} end
# 
# """
# 		dim(x::Geometry)
# 
# Returns the *a priori* dimension of `x`, i.e. 2 if `x` is built purely
# out of planar objects, and 3 otherwise.
# """
# @inline dim(::Geometry{D}) where{D} = D
# @inline eltype(::Type{<:Geometry{D,T}}) where{D,T} = T

# Return top-level objects from included file««1

# FIXME: replace Main by caller module?
# FIXME: add some blob to represent function arguments
"""
		Solids.include(file::AbstractString, f::Function)

Reads given `file` and returns the union of all top-level `Solids` objects
(except the results of assignments) found in the file.

```
#### Example: contents of file `example.jl`
C=Solids.Cube(1)
S=Solids.Square(1)
Solids.Circle(3)
S

julia> Solids.include("example.jl")
union() {
 circle(radius=3.0);
 square(size=[1.0, 1.0], center=false);
}
```

"""
function include(file::AbstractString)
	global toplevel_objs = AbstractGeometry[]
	Base.include(x->expr_filter(obj_filter, x), Main, file)
	return union(toplevel_objs...)
end
# # TODO: somehow attach a comment indicating the origin of these objects
# # last_linenumber holds the last LineNumberNode value encountered before
# # printing this object; we use this to insert relevant comments in the
"""
    obj_filter(x)

Appends `x` to the global list of returned objects if `x` is a `AbstractGeometry`.
"""
@inline obj_filter(x) = x
@inline obj_filter(x::AbstractGeometry) =
	(global toplevel_objs; push!(toplevel_objs, x); return x)

"""
		expr_filter(E)

Read top-level expression `E` and decides if a Solids object is returned.

The function `expr_filter` transforms top-level expressions by wrapping
each non-assignment expression inside a call to function `obj_filter`,
which can then dispatch on the type of the expression.
"""
# Numeric values, LineNumber expressions etc. will never be useful to us:
expr_filter(f::Function, e::Any) = e
# expr_filter(e::LineNumberNode) = (global last_linenumber = e)
# A Symbol might be an AbstractGeometry variable name, so we add it:
expr_filter(f::Function, e::Symbol) = :($f($e))

# we add any top-level expressions, except assignments:
expr_filter(f::Function, e::Expr) = expr_filter(f, Val(e.head), e)
expr_filter(f::Function, ::Val, e::Expr) = :($f($e))
expr_filter(f::Function, ::Val{:(=)}, e::Expr) = e

# if several expressions are semicolon-chained, we pass this down
expr_filter(f::Function, ::Val{:toplevel}, x::Expr) =
	Expr(:toplevel, expr_filter.(f, x.args)...)

# Primitive solids««1
# Generic code««2
"""
    PrimitiveSolid{S,D,T,X}

A type used to factorize code for the various primitive solids.
`D` and `T` are as usual the dimension and coordinate type.
`S` is a symbol indicating the type of solid (`:square`, etc.);
`X` is a NamedTuple type holding the parameters for this solid
(e.g. `@NamedTuple{radius::T}` for a sphere).

From the info in `X` we can derive a default constructor
(using keyword arguments matching the `NamedTuple`) and a
`show` method.

The coordinate type `T` is guessed from the values of the tuple using the
`_infer_type(H;kwargs...)` method.
"""
struct PrimitiveSolid{S,D,T,X} <: AbstractGeometry{D,T}
	parameters::X
	@inline PrimitiveSolid{S,D,T,X}(;kwargs...) where{S,D,T,X} =
		new{S,D,T,X}(kwargs.data)
end
@inline (H::Type{<:PrimitiveSolid{S,D,T}})(;kwargs...) where{S,D,T} =
	H{typeof(kwargs.data)}(kwargs.data)
@inline (H::Type{<:PrimitiveSolid{S,D}})(;kwargs...) where{S,D} =
	H{_infer_type(H;kwargs...)}(;kwargs...)

@inline scad_name(::PrimitiveSolid{S}) where{S} = S
@inline parameters(s::PrimitiveSolid) = getfield(s, :parameters)
@inline Base.getproperty(s::PrimitiveSolid, name::Symbol) =
	Base.getproperty(parameters(s), name)

# Glue for types imported from Meshes.jl: Square, Cube, Circle, Sphere««2
# --mesh
@inline Rect{D}(p1::AbstractVector, p2::AbstractVector) where{D} =
	Rect{D,promote_type(eltype.((p1,p2))...)}(Point{D}(p1), Point{D}(p2))
@inline function Rect{D}(v::AbstractVector;
		origin=zero(v), center=false) where{D}
	p1 = center ? origin - one_half(v) : origin
	return Rect{D}(p1, p1+v)
end
@inline Rect{D}(a::Number; kwargs...) where{D} =
	Rect{D}(Vec{D}(a for _ in 1:D); kwargs...)

"""
    Square(size; origin, center=false)

An axis-parallel square or rectangle  with given `size`
(scalar or vector of length 2).
"""
Square = Rect{2}
"""
    Cube(size; origin, center=false)

A cube or parallelepiped  with given `size`
(scalar or vector of length 3).
"""
Cube = Rect{3}

@inline HyperSphere{D}(r::T) where{D,T} =
	HyperSphere(Point(zero(SVector{D,T})), r)
"""
    Circle(radius)

A circle. Discretization is done via the `accuracy` and `precision`
parameters.
"""
Circle
"""
    Sphere(radius)

A sphere. Discretization is done via the `accuracy` and `precision`
parameters.
"""
Sphere
struct Cylinder{T} <: GeometryBasics.GeometryPrimitive{3,T}
	origin::Point{3,T}
	radius::T
	height::T
end
# Cylinder ««2
# """
#     Cylinder(h, r1, r2 [, center=false])
#     Cylinder(h, (r1, r2) [, center=false])
#     Cylinder(h, r [, center=false])
# 
# **Warning:** `Cylinder(h,r)` is interpreted as `Cylinder(h,r,r)`,
# not `(h,r,0)` as in OpenSCAD.
# """
# Cylinder{T} = PrimitiveSolid{:cylinder,3,T,
# 	@NamedTuple{r1::T,r2::T,h::T,center::Bool}}
# @inline _infer_type(::Type{<:Cylinder}; h,r1,r2,center) = real_type(h, r1, r2)
# @inline (H::Type{<:Cylinder})(h, r1,r2; center=false) =
# 	H(r1=r1, r2=r2, h=h, center=center)
# @inline (H::Type{<:Cylinder})(h, r; kwargs...) = H(h, r, r; kwargs...)
# @inline (H::Type{<:Cylinder})(h, r::Union{AbstractVector, Tuple}; kwargs...) =
# 	H(h, r...; kwargs...)
# 
# Polygon ««2
"""
    Polygon{T}
    Polygon([point1, point2, ...])
    Polygon(point1, point2, ...)

A simple, closed polygon enclosed by the given vertices.
"""
struct Polygon{T} <: AbstractGeometry{2,T}
	points::Vector{Point{2,T}}
	@inline Polygon(points::AbstractVector{<:Point{2}}) =
		new{real_type(eltype.(points)...)}(points)
	@inline Polygon(points::AbstractVector{<:AbstractVector{<:Real}}) =
		Polygon(Point.(points))
	@inline Polygon(points::AbstractVector{<:Real}...) = Polygon([points...])
	# points in rows, for easy notation:
	@inline Polygon(m::AbstractMatrix{<:Real}) =
		Polygon([m[i,:] for i in 1:size(m,1)])
end
# Polygon{T} = PrimitiveSolid{:polygon,2,T,
# 	@NamedTuple{points::Path{2,T}}}
# @inline _infer_type(::Type{<:Polygon}; points) = real_type(eltype.(points)...)
# @inline (T::Type{<:Polygon})(points::AnyPath{2}) = T(points=points)
# @inline (T::Type{<:Polygon})(points::AnyVec{2,<:Real}...) = T([points...])

@inline vertices(p::Polygon) = p.points
# Surface««2
# TODO also store some face-neighbour information
# this can be updated (not fully recomputed) for subtriangulation
"""
    AbstractSurface{T,F}
    Surface([points...], [faces...])

Encodes information about a surface.

Parameters
 - `T` is the coordinate type
 - `F` is the type used for storing a face (e.g. `SVector{3,Int}`)

Interface
 - `vertices(s)`: `AbstractDictionary` of indices
 - `faces(s)`: `AbstractDictionary` of faces

Triangle{D,T}=TriangleP{D,T,Point{D,T}}= points::SVector{3,Point{4,T}}
TriangleFace{T}=NGonFace{3,T}= data:: NTuple{3,T}
PlainMesh{D,T}=TriangleMesh{D,T,Point{D,T}}=
	AbstractMesh{Triangle{D,T}} has faces Triangle{D,T} **abstract**
abstract type AbstractMesh{Element<:Polytope} <: AbstractVector{Element} end

Mesh{3,T,Triangle{3,T}, faceview...} = simplices::V

FaceView{E,P,F,PV,FV}~Vector{E} = elements::PV, faces::FV
ici FaceView{Triangle{3,T},Point{3,T}, **Face**,
	Vector{Point{3,T}},Vector{**Face**}
 == SimpleFaceView{3,T,3,Int,Point{3,T},TriangleFace{T}}

struct FaceView{Element,Point <: AbstractPoint,Face <: AbstractFace,P <: AbstractVector{Point},F <: AbstractVector{Face}} <: AbstractVector{Element}
    elements::P
    faces::F
end
struct Mesh{Dim,T<:Number,Element<:Polytope{Dim,T},V<:AbstractVector{Element}} <: AbstractMesh{Element}
const FaceMesh{Dim,T,Element} = Mesh{Dim,T,Element,<:FaceView{Element}}
"""
AbstractSurface = GeometryBasics.PlainMesh
surface(points::AbstractVector{<:Point{3}},
	faces::AbstractVector{<:AbstractVector{<:Integer}}) =
	GeometryBasics.Mesh(Point{3,real_type(eltype.(points)...)}.(points),
		GeometryBasics.TriangleFace{Int}.(faces))

vertices(s::AbstractGeometry) = GeometryBasics.coordinates(s)
vertices(s::GeometryBasics.AbstractMesh) = GeometryBasics.coordinates(s)
nvertices(s::AbstractSurface) = length(vertices(s))
faces(s::AbstractSurface) = GeometryBasics.faces(s)
nfaces(s::AbstractSurface) = length(faces(s))

AbstractTriangulatedSurface{T} =
	GeometryBasics.AbstractMesh{<:GeometryBasics.TriangleP{3,T}}
# fieldnames(TriangulatedSurface):
#   simplices::FaceView{...}
# fieldnames(FaceView{...}):
#   elements::Vector{Point{3,T}}
#   faces::Vector{TriangleFace{Int}}
# TriangleFace{Int}:
#   data::NTuple{3,Int}

# concrete type:
# XXX is this even needed?
TriangulatedSurface{T} = GeometryBasics.Mesh{3,T,Triangle{3,T},
	GeometryBasics.SimpleFaceView{3,T,3,Int,Point{3,T},
		GeometryBasics.TriangleFace{Int}}}
Base.show(io::IO, ::Type{TriangulatedSurface{T}}) where{T<:Real} =
	print(io, "TriangulatedSurface{$T}")
TriangulatedSurface(
		points::AbstractVector{<:Point},
		faces::AbstractVector{<:Vector{Int}}) =
	surface(points, faces)
# fields are simplices.elements:: Vector{Point{3,T}}
#            simplices.faces::Vector{TriangleFace{Int}}
#            simplices.faces[1].data::NTuple{3,Int}
@inline nvertices(s::AbstractSurface) = length(vertices(s))
@inline nfaces(s::AbstractSurface) = length(faces(s))
@inline facetype(s::AbstractSurface{T,F}) where{T,F} = F

# abstract type AbstractTriangulatedSurface{T} <:
# 	AbstractSurface{T,SVector{3,Int}} end

# @inline AbstractMeshes.Triangle(s::AbstractTriangulatedSurface, i) =
# 	Triangle(vertices(s)[faces(s)[i]])
# 
# struct TriangulatedSurface{T} <: AbstractTriangulatedSurface{T}
# 	vertices::Vector{Point{3,T}}
# 	faces::Vector{SVector{3,Int}}
# end
# @inline TriangulatedSurface(points, faces) =
# 	TriangulatedSurface{real_type(coordtype.(points)...)}(points, faces)
# @inline faces(s::TriangulatedSurface) = s.faces
# @inline vertices(s::TriangulatedSurface) = s.vertices

struct SurfaceFacesView{T,F} <:
	AbstractSurface{T,F}
	parent::AbstractSurface{T,F}
	indices::Vector{Int}
end
@inline faces(s::SurfaceFacesView) = indexedview(faces(s.parent), s.indices)
@inline vertices(s::SurfaceFacesView) = vertices(s.parent)

@inline indexedview(s::AbstractSurface, indices) = SurfaceFacesView(s, indices)

# a lot of functions operating on 'Surface' values are defined later in
# the meshing part of this file.

# Neutral solids««2
"""
    NeutralSolid{D,T}

A convenience type representing either an empty or full solid.
This exists mostly to provide a neutral element
for `union()` and `intersect()` operators, hence the name.
In those cases, it is impossible to know in advance
the dimension of the returned solid;
hence, as an exception to the general rule,
the `D` type parameter is either the symbol `:empty` or `:full`.

Since neutral objects are removed at compile-time
from corresponding CSG operations,
this should have no influence on the dimension of a top-level object.

The `T` type parameter is always `Bool`.
"""
struct NeutralSolid{D,T} <: AbstractGeometry{D,T} end
@inline scad_name(::NeutralSolid{D}) where{D} = D
# @inline parameters(::IO, ::NeutralSolid) = nothing

macro define_neutral(op, what, result)
	W = QuoteNode(what)
	F=:(Solids.$op)
	quote
	@inline $F(neutral::AbstractGeometry, absorb::NeutralSolid{$W}) = $result
	@inline $F(absorb::NeutralSolid{$W}, neutral::AbstractGeometry) = $result
	@inline $F(x::NeutralSolid{$W}, ::NeutralSolid{$W}) = x
	end
end
@inline union() = NeutralSolid{:empty,Bool}()
@inline intersect() = NeutralSolid{:full,Bool}()

# these are necessary for the following macros:
function minkowski end
function hull end
@define_neutral union empty neutral
@define_neutral union full  absorb
@define_neutral intersect empty absorb
@define_neutral intersect full  neutral
@define_neutral minkowski empty absorb
@define_neutral minkowski full  absorb
@define_neutral hull empty neutral
@define_neutral hull full  absorb

# # Somewhat reduce type I/O clutter««1
# Base.show(io::IO, ::Type{_FIXED}) = print(io, "_FIXED")
# Base.show(io::IO, ::Type{Vec}) = print(io, "Vec")
# # Base.show(io::IO, ::Type{Vec{3}}) = print(io, Vec,"{3}")
# # Base.show(io::IO, ::Type{Vec{3}}) = print(io, Vec,"{3}")
# # Base.show(io::IO, ::Type{Vec{D,T}}) where{D,T<:Number} = print(io, Vec,"{$D,$T}")
# # Base.show(io::IO, ::Type{Path}) = print(io, "Path")
# # Base.show(io::IO, ::Type{Path{D}}) where{D} = print(io, Path,"{$D}")
# # Base.show(io::IO, ::Type{Path{D,T}}) where{D,T<:Number} = print(io, Path,"{$D,$T}")
# for type in (:Square, :Cube, :Circle, :Sphere, :Cylinder, :Polygon)
# 	@eval begin
# 		Base.show(io::IO, ::Type{$type}) = print(io, $(String(type)))
# 		Base.show(io::IO, ::Type{$type{T}}) where{T} =
# 			print(io, $(String(type)), "{$T}")
# 	end
# end
# 
#ConstructedSolid««1
# https://www.usenix.org/legacy/event/usenix05/tech/freenix/full_papers/kirsch/kirsch.pdf
"""
		ConstructedSolid{D,S}

A type representing CSG operations on solids. `D` is the dimension and
`S` is a symbol representing the operation (union, intersection etc.)
"""
struct ConstructedSolid{S,V,D,T} <: AbstractGeometry{D,T}
	children::V # Vector{<:AbstractGeometry}, or tuple etc.
	# passing a vector or tuple:
	@inline ConstructedSolid{S,V,D,T}(v::V) where{S,V,D,T} = new{S,V,D,T}(v)
end
@inline ConstructedSolid{S,V,D}(s) where{S,V,D} =
	ConstructedSolid{S,V,D,real_type(coordtype.(s)...)}(s)
@inline children(s::ConstructedSolid) = s.children
@inline scad_name(::ConstructedSolid{S}) where{S} = S

ConstructedSolid(s::Symbol, T = Vector{<:AbstractGeometry}) = ConstructedSolid{s,T}
CSGUnion = ConstructedSolid(:union)
CSGInter = ConstructedSolid(:intersection)
CSGDiff = ConstructedSolid(:difference,Tuple{<:AbstractGeometry,<:AbstractGeometry})
CSGComplement = ConstructedSolid(:complement,Tuple{<:AbstractGeometry})
CSGHull = ConstructedSolid(:hull)
CSGMinkowski = ConstructedSolid(:minkowski)
# @inline scad_name(::ConstructedSolid{D, :intersection}) where{D} = :intersection

# make operators associative; see definition of + in operators.jl
for op in (:union, :intersect, :minkowski, :hull)
	Q=QuoteNode(op)
	# union, intersection, minkowski are trivial on single objects:
	op != :hull &&  @eval ($op)(a::AbstractGeometry) = a
	@eval begin
	# all of these are associative:
	# we leave out the binary case, which will be defined on a case-by-case
	# basis depending on the operators (see below).
#		($op)(a::AbstractGeometry, b::AbstractGeometry) =
#			ConstructedSolid{$Q}([unroll(a, Val($Q)); unroll(b, Val($Q))])
	($op)(a::AbstractGeometry, b::AbstractGeometry, c::AbstractGeometry, x...) =
		Base.afoldl($op, ($op)(($op)(a,b),c), x...)
	end
end

"""
    union(s::AbstractGeometry...)
    s1 ∪ s2

Represents the union of given solids.
"""
@inline union(a1::AbstractGeometry{D1}, a2::AbstractGeometry{D2}) where{D1, D2} =
	CSGUnion{max(D1,D2)}(unroll2(a1, a2, Val(:union)))
"""
    intersect(s::AbstractGeometry...)
    s1 ∩ s2

Represents the intersection of given solids.
"""
@inline intersect(a1::AbstractGeometry{D1}, a2::AbstractGeometry{D2}) where{D1, D2} =
	CSGInter{min(D1,D2)}(unroll2(a1, a2, Val(:intersection)))
"""
    minkowski(s::AbstractGeometry...)

Represents the Minkowski sum of given solids.
"""
@inline minkowski(a1::AbstractGeometry{D1}, a2::AbstractGeometry{D2}) where{D1, D2} =
	CSGMinkowski{max(D1,D2)}(unroll2(a1, a2, Val(:minkowski)))
"""
    hull(s::AbstractGeometry...)

Represents the convex hull of given solids.
"""
@inline hull(s::AbstractGeometry...) =
	CSGHull{maximum(embeddim.(s))}(
		[unroll(t, Val.((:hull, :union))...) for t in s])

"""
		unroll(x::AbstractGeometry, Val(sym1), Val(sym2)...)

Returns either `[x]` or, if `x` is a `ConstructedSolid` matching one of the
symbols `sym1`, `sym2`..., `children(x)`. (This helps reduce nesting).
"""
@inline unroll(s::AbstractGeometry, ::Val, tail...) = unroll(s, tail...)
@inline unroll(s::AbstractGeometry) = s
@inline unroll(s::ConstructedSolid{D, S}, ::Val{S}, tail...) where{D, S} =
	children(s)
@inline unroll2(s::AbstractGeometry, t::AbstractGeometry, tail...) =
	[unroll(s, tail...); unroll(t, tail...)]

# minus operator is binary:
"""
    Solids.difference(s1, s2)

Represents the difference `s1 ∖ s2`.
"""
@inline difference(x::AbstractGeometry{D1}, y::AbstractGeometry) where{D1} =
	CSGDiff{embeddim(x)}((x, y))
# 		[unroll(x, Val(:difference)); unroll.(y, Val(:union))...])
# added interface: difference([x...], [y...])
@inline difference(x::AbstractVector{<:AbstractGeometry},
				y::AbstractVector{<:AbstractGeometry}) =
	difference(union(x...), union(y...))
# 	ConstructedSolid{foldr(max,embeddim.(x);init=2),:difference}(union(x...), y...)

@inline complement(x::AbstractGeometry{D}) where{D} =
	CSGComplement{embeddim(x)}((x,))

# General transforms««1
# Curry««2
"""
    Curry{S}

A structure representing partially-evaluated functions.
This allows chaining transformations by overloading the multiplication
operator: each factor in such a 'product', except the last one,
is a `Curry` object.

`S` is a datum indicating the type of transformation performed by the
function. It is used to compose functions when possible.

# Examples
```jldoctest
julia> add(a)=Curry(x->x+a)
julia> add(1)*add(2)*4
7
```
"""
struct Curry{S}
  f # either a Function or a Type...
end
# poor man's associative functor...

# fall-back case:
@inline Base.:*(f::Curry) = f
# binary rules:
@inline Base.:*(f::Curry, g::Curry) = compose(f, g)
@inline Base.:*(f::Curry, x) = f.f(x)
# ternary rule for associativity: we use the `assoc` type trait to
# decide whether to associate left or right.
@inline Base.:*(f::Curry, g::Curry, args...) =
	_comp(Val(assoc(f,g)), f, g, args...)
@inline _comp(::Val{:left} , f, g, args...) = *(compose(f, g), args...)
@inline _comp(::Val{:right}, f, g, args...) = *(f, *(g, args...))

# default values for the traits: transforms are right-associative and
# composition is trivial.
@inline assoc(::Curry, ::Curry) = :right
@inline compose(f::Curry, g::Curry) = Curry{:∘}(f.f ∘ g.f)

# Transform type««2
"""
    Transform{S,D,T,X}

Represents a solid of dimension `D` obtained via a transformation with
name `S` (a symbol).

This type defines functions allowing to chain transforms; these are used by
`multmatrix`, `color` etc. operations (see below).

The minimal job left to concrete types (see e.g. `AffineTransform` as an
example) is to define a type and a constructor:
    Frobnicate = Transform{:frobnicate}
		frobnicate(x::real, s...) = Frobnicate((x=x,), s...)
"""
struct Transform{S,D,T,X} <: AbstractGeometry{D,T}
	child::AbstractGeometry{D,T}
	data::X
	Transform{S}(data::X, child::AbstractGeometry{D,T}) where{S,X,D,T} =
		new{S,D,T,X}(child, data)
end
# default values for I/O:
# (parameters in `data` are assumed to be stored in a NamedTuple).
@inline children(f::Transform) = [f.child]
@inline scad_name(f::Transform{S}) where{S} = S
@inline parameters(f::Transform) = f.data
@inline (T::Type{Transform{S}})(f, s::AbstractGeometry...) where{S} =
	T(f, union(s...))
@inline (T::Type{Transform{S}})(f, s::Vector{<:AbstractGeometry}) where{S} =
	T(f, s...)
@inline (T::Type{Transform{S}})(f) where{S} = Curry{S}((s...)->T(f, s...))
# We can extract the `f` value from the above in the following way:
"""
    extract(c::Curry)

Given a `Curry` object with function `s -> Transform{...}(f, s)`,
recovers the parameter `f`.
"""
function extract end
@inline (T::Type{<:Transform})(f, ::typeof(extract)) = f
@inline extract(c::Curry) = c.f(extract)

# SetParameters««2
SetParameters = Transform{:parameters}
"""
    set_parameters(;accuracy=accuracy, precision=precision)

A transformation which passes down the specified parameter values to its
child. Roughly similar to setting `\$fs` and `\$fa` in OpenSCAD.
"""
@inline set_parameters(s...; parameters...) =
	SetParameters(parameters.data, s...)

# Color««2
Color = Transform{:color}

"""
    color(c::Colorant, s...)
    color(c::AbstractString, s...)
    color(c::AbstractString, α::Real, s...)
    color(c) * s...

Colors objects `s...` in the given color.
"""
@inline color(c::Colors.Colorant, s...) = Color((color=c,), s...)
@inline color(c::AbstractString, s...) =
	color(parse(Colors.Colorant, c), s...)
@inline color(c::AbstractString, a::Real, s...) =
	color(Colors.coloralpha(parse(Colors.Colorant, c), a), s...)

# Linear extrusion««2
LinearExtrude = Transform{:linear_extrude}
"""
    linear_extrude(h, s...)
    linear_extrude(h) * s...

Linear extrusion to height `h`.
"""
@inline linear_extrude(h, scale::AbstractVector, s...; center=false)=
	LinearExtrude((height=h, scale=scale, center=center,), s...)
@inline linear_extrude(h, scale::Real, s...; kwargs...) =
	linear_extrude(h, SA[scale, scale], s...; kwargs...)
@inline linear_extrude(h, s...; kwargs...) =
	linear_extrude(h, 1, s...; kwargs...)

# Rotational extrusion««2
RotateExtrude = Transform{:rotate_extrude}
@inline rotate_extrude(angle::Real, s...; center=false) =
	RotateExtrude((angle=angle, center=center), s...)
@inline rotate_extrude(s...) = rotate_extrude(360, s...)
# Offset
Offset = Transform{:offset}
@inline offset(r::Real, s...; join=:round, miter_limit=2.) =
	Offset((r=r, join=join, miter_limit=miter_limit), s...)
@inline scad_parameters(io::IO, s::Offset) =
	scad_parameters(io, s, Val(parameters(s).join), parameters(s))
@inline scad_parameters(io::IO, ::Offset, ::Val{:round}, param) =
	scad_parameters(io, (r=param.r,))
@inline scad_parameters(io::IO, ::Offset, ::Val{:miter}, param) =
	scad_parameters(io, (delta=param.r, chamfer=false,))
@inline scad_parameters(io::IO, ::Offset, ::Val{:square}, param) =
	scad_parameters(io, (delta=param.r, chamfer=true,))

# Affine transforms««1
# Affine type««2
# type and constructors««3
"""
    Affine(a, b)
		Affine(a)
		Affine(a, center=c)

A structure representing an affine transformation `x -> a*x + b`.
This is purposely kept as generic as possible.

As a special case, `a == Val(true)` corresponds to translations,
while `b == Val(false)` corresponds to linear maps. (The `+` and `*`
operators are overloaded correspondingly).
"""
struct Affine{A,B}
	a::A
	b::B
end
# default constructors: Affine{A,B}(::A,::B), Affine(::A,::B)
# @inline Affine(a; center) = Affine(a, a*center - center)
@inline Affine(a;center=Val(false)) = Affine(a, Val(false))

@inline (f::Affine)(p::Point) = Point(f.a * p + f.b)
# @inline apply(f::Affine, p::Point) = Point(f.a * v.coords + f.b)
# @inline apply(f::Affine, points::AbstractVector{<:Point}) =
# 	[apply(f, p) for p in points]

@inline sign(f::Affine{<:Number}) = sign(f.a)
@inline sign(f::Affine{<:AbstractMatrix}) = sign(det(f.a))

# neutral elements: ««3
# this could in principle be defined for Val{T} where{T}, but we try
# to pirate a minimum number of functions in Base.
@inline Base.:*(::Val{true}, v) = v
@inline Base.:*(a, v::Val{false}) = v
@inline Base.:+(v, ::Val{false}) = v
@inline Base.:-(v, ::Val{false}) = v

# I/O: ««3
# OpenSCAD only uses 4×4 matrices for transformations;
# we pad the matrix to this size if needed:
function scad_parameters(io::IO, f::Affine)
	m = [ mat33(f.a) vec3(f.b); 0 0 0 1 ]
	print(io, "[")
	join(io, map(i->Float64.(view(m,i,:)),1:size(m,1)),",")
	print(io, "]")
end

@inline mat33(a::AbstractMatrix) = [ get(a, (i,j), i==j) for i=1:3, j=1:3 ]
@inline mat33(a::Diagonal) = Diagonal(vec3(diag(a)))
@inline mat33(a::Real) = SDiagonal(a,a,a)
@inline mat33(::Val{b}) where{b} = mat33(b)

@inline vec3(b::AbstractVector) = SVector{3}(get(b, i, 0) for i in 1:3)
@inline vec3(::Val{b}) where{b} = SA[b, b, b]

# Reflections««2
"""
		Reflection

A type containing compressed information for an orthogonal reflection
matrix. Inspired by the `Diagonal` type.
"""
struct Reflection{D,T,V<:AbstractVector} <: AbstractMatrix{T}
	axis::V
	@inline Reflection{D,T,V}(v::V) where {D,T,V<:AbstractVector{T}} =
		new{D,T,V}(v)
end
# we use only static vectors in Reflections:
@inline Reflection(v::AbstractVector) = Reflection(SVector{length(v)}(v))
# FIXME: add some method where we know that v is normed already
@inline Reflection(v::Vec{D}) where{D} = let u = v/norm(v)
	Reflection{D,typeof(u[1]),typeof(u)}(u)
end
# Mat{3}(R::Reflection{2}) = Reflection([R.axis;SA[0]])

@inline size(R::Reflection{D}) where{D} = (D,D)
@inline getindex(R::Reflection{D}, i::Int) where{D} =
	getindex(R, fld1(i,D), mod1(i,D))
@inline getindex(R::Reflection, i::Int, j::Int) = let a = R.axis
	(i == j) - 2*a[i]*a[j]
end
function Matrix{T}(R::Reflection{D,T}) where{D,T}
	# R(x) = x - 2<x, axis>/‖axis‖² · axis
	a = R.axis
	I(D) - 2*a*a'
end

# AffineTransform««2
AffineTransform = Transform{:multmatrix}

"""
    mult_matrix(a, [center=c], solid...)
    mult_matrix(a, b, solid...)
    mult_matrix(a, b) * solid

Represents the affine operation `x -> a*x + b`.

# Extended help
!!! note "Types of `mult_matrix` parameters"

    The precise type of parameters `a` and `b` is not specified.
    Usually, `a` will be a matrix and `b` a vector, but this is left open
    on purpose; for instance, `a` can be a scalar (for a scaling)
    and `b` can be `Val(false)` for a linear operation. Any types so that
    `a * Vector + b` is defined will be accepted.

    Conversion to a matrix will be done when converting to OpenSCAD
    format.

!!! note "Matrix multiplication"

    Chained `mult_matrix` operations will be combined into a single
    operation when possible. This saves time: multiple
    (3 × n) matrix multiplications are replaced by
    (3 × 3) multiplications, followed by a single (3 × n).
"""
@inline mult_matrix(a, s...; kwargs...) =
	AffineTransform(Affine(a; kwargs...), s...)
@inline mult_matrix(a, b::Union{AbstractVector,Val{false}}, s...) =
	AffineTransform(Affine(a, b), s...)
@inline parameters(s::AffineTransform) = (m=s.data,)

# these two functions are now enough to pre-compose all affine transforms
# *before* applying them to objects:
@inline assoc(::Curry{:multmatrix}, ::Curry{:multmatrix}) = :left
@inline function compose(c1::Curry{:multmatrix}, c2::Curry{:multmatrix})
	(f1, f2) = (extract(c1), extract(c2))
	mult_matrix(f1.a*f2.a, f1.a*f2.b + f1.b)
end

# Translation, scaling, rotation, mirror««2
# FIXME change this '1' to a compile-time constant?
"""
    translate(v, s...)
    translate(v) * s

Translates solids `s...` by vector `v`.
"""
@inline translate(v::AbstractVector, s...) = mult_matrix(1, v, s...)
"""
    scale(a, s...; center=0)
    scale(a; center=0) * s
Scales solids `s` by factor `a`. If `center` is given then this will be
the invariant point.

`a` may also be a vector, in which case coordinates will be multiplied by
the associated diagonal matrix.
"""
@inline scale(a::Real, s...; kwargs...) = mult_matrix(a, s...; kwargs...)
@inline scale(a::AbstractVector, s...; kwargs...) =
	mult_matrix(Diagonal(a), s...; kwargs...)
"""
    mirror(v, s...; center=0)
    mirror(v; center=0) * s

Reflection with axis given by the hyperplane normal to `v`.
If `center` is given, then the affine hyperplane through this point will
be used.
"""
@inline mirror(v::AbstractVector, s...; kwargs...) =
	mult_matrix(Reflection(v), s...; kwargs...)

@inline rotation(θ::AnyAngle; axis=SA[0,0,1], kwargs...) =
	real_type(θ,axis...).(Rotations.AngleAxis(radians(θ), axis...))
@inline rotation(θ::AnyList{<:AnyAngle}; kwargs...) =
	real_type(θ,axis...).(Rotations.RotZYX(radians.(θ); kwargs...))

"""
    rotate(θ, {center=center}, {solid...})
    rotate(θ, axis=axis, {center=center}, {solid...})

Rotation around the Z-axis (in trigonometric direction, i.e.
counter-clockwise).
"""
@inline rotate(θ, s...; kwargs...) = mult_matrix(rotation(θ; kwargs...), s...)
"""
    rotate((θ,φ,ψ), {center=center}, {solid...})

Rotation given by Euler angles (ZYX; same ordering as OpenSCAD).
"""
@inline rotate(θ::Real, φ::Real, ψ::Real, s...; kwargs...) =
	mult_matrix(rotation((θ,φ,ψ); kwargs...), s...)

# Operators««2
@inline +(v::AbstractVector, x::AbstractGeometry) = translate(v,x)
@inline +(x::AbstractGeometry, v::AbstractVector) = translate(v,x)

# this purposely does not define a method for -(x::AbstractGeometry).
@inline Base.:-(x::AbstractGeometry, y::AbstractGeometry, tail...) =
	difference(x, [y, tail...])
@inline Base.:-(x::AbstractGeometry{D}) where{D} = difference(intersect(), x)
@inline Base.:-(x::AbstractVector{<:AbstractGeometry},
                y::AbstractVector{<:AbstractGeometry}) = difference(x, y)

# @inline *(f::AbstractAffineMap, x::AbstractGeometry) = mult_matrix(f, x)
@inline *(s::Union{Real,AbstractVector}, x::AbstractGeometry) = scale(s,x)

⋃ = Base.union
⋂ = Base.intersect

# OpenSCAD output ««1
@inline indent(io::IO) = print(io, " "^get(io, :indent, 0))
@inline add_indent(io::IO, n=1) =
	IOContext(io, :indent => get(io, :indent, 0)+1)
@inline function Base.show(io::IO, l::AbstractGeometry...)
	for s in l
		indent(io); scad(io, s)
	end
end

@inline children(::AbstractGeometry) = nothing
@inline parameters(::AbstractGeometry) = NamedTuple()

"""
    scad(filename::AbstractString, s::AbstractGeometry...)
    scad(io::IO, s::AbstractGeometry)

Prints an OpenSCAD-like representation of the given solid(s).

## The various `scad_*` functions

    `scad_name(s)`
Returns, in printable form (e.g. `Symbol` or `String`), the OpenSCAD name
of this object.

    `scad_parameters(s)`
Returns a `NamedTuple` representing parameters of this object.

    `scad_transform(s)`
Possible transformation prepended to the object.

    `to_scad(x)`
Represents value `x` (number, array, etc.) in OpenSCAD format.

"""
function scad(io::IO, s::AbstractGeometry)
	indent(io)
	print(io, scad_transform(s))
	print(io, scad_name(s), "(")
	f = true;
	for (k, v) in pairs(scad_parameters(s))
		if f f = false; else print(io, ", "); end
		print(io, k, "=", to_scad(v))
	end
	print(io, ")")
	if children(s) isa Nothing
		println(io, ";")
	else
		scad_children(io, s)
	end
end

@inline scad(filename::AbstractString, L::AbstractGeometry...) =
	open(filename, "w") do f scad(f, l...) end

function scad_children(io::IO, s::AbstractGeometry)
	print(io, " {\n")
	io2 = add_indent(io)
	for c in children(s)
		scad(io2, c)
	end
	indent(io); print(io, "}")
end

@inline scad_name(::Square) = :square
@inline scad_name(::Cube) = :cube
@inline scad_name(::Circle) = :circle
@inline scad_name(::Sphere) = :sphere
@inline scad_name(::Polygon) = :polygon

@inline scad_parameters(s::AbstractGeometry) = parameters(s)
@inline scad_parameters(s::Rect) = (size=Vector{Float64}(s.max - s.min),)
@inline scad_parameters(s::HyperSphere) = (r=s.radius,)
@inline scad_parameters(p::Polygon) = (points=p.points,)

@inline scad_transform(s::AbstractGeometry) = ""
@inline scad_transform(s::Rect) = scad_translate(s.min)
@inline scad_transform(s::HyperSphere) = scad_translate(s.center)
@inline scad_translate(p::Point) =
	iszero(coordinates(p)) ? "" : string("translate", to_scad(p), ")")

@inline to_scad(x) = x
@inline to_scad(p::Point) = Vector{Float64}(coordinates(p))
# kill any SVector{...} appearing in output:
@inline to_scad(v::AbstractVector) = Vector(to_scad.(v))
@inline to_scad(c::Colors.Colorant) = round.(Float64.([
	Colors.red(c), Colors.green(c), Colors.blue(c), Colors.alpha(c)]), digits=3)

# special case: Surface, with annotations for points
function scad(io::IO, s::AbstractSurface)
	println(io, "polyhedron(points=[ // ", nvertices(s), " points:")
	for (i,p) in pairs(vertices(s))
		indent(io)
		print(io, " ", Vector{Float64}(p))
		if i < nvertices(s) print(io, ","); end
		println(io, " // ", i)
	end
	println(io, "],[ // ", nfaces(s), " faces:")
	for (i,f) in pairs(faces(s))
		indent(io)
		print(io, " ", Vector(f .- 1))
		if i < nfaces(s) print(io, ","); end
		println(io, " // ", i)
	end
	indent(io); println(io, "] );")
end

function scad(io::IO, s::SetParameters)
	indent(io); println(io, "{ // SetParameters")
	for (i,j) in pairs(s.data)
		indent(io); println(io, "// ", i, "=", j, ";")
	end
	scad(io, s.child)
	indent(io); println(io, "} // SetParameters")
end

# # Attachments««1
# # Anchor system««2
# """
# 		find_anchor(x::AbstractGeometry, name)
# 
# Returns the anchor (an affine rotation) found for the given `name` for
# the solid `x`.
# 
# Some types of `name` that can be used include:
#  - a symbol: either one of the six standard directions (`:left`, `:right`,
# 	 `:front`, `:back`, `:top`, `:bottom`, `:center`)
# 	 or a custom-defined label (TODO);
# 	 (*Note:* for 2-dimensional solids, `:bottom` is equivalent to `:front`
# 	 and `:top` is equivalent to `:back`)
#  - a list (tuple) of symbols, which is interpreted as the sum of the
# 	 corresponding directions;
#  - for standard convex bodies, a vector of the same dimension as `x` is
# 	 normalized to a point at the boundary of `x` (see below);
#  - a way to designate a point at the boundary of `x` (see below).
# """
# @inline find_anchor(x::AbstractGeometry, labels::NTuple{N,Symbol}) where{N} =
# 	find_anchor(x, sum([ labeled_anchor(x, l) for l in labels]))
# @inline function find_anchor(x::AbstractGeometry, label::Symbol)
# 	y = labeled_anchor(x, label)
# 	y isa Missing && error("No anchor named '$label' found in $(scad_name(x))")
# 	return find_anchor(x, y)
# end
# 
# default_positions = (
# 	left  = SA[-1,0,0],
# 	right = SA[+1,0,0],
# 	front = SA[0,-1,0],
# 	back  = SA[0,+1,0],
# 	bot	  = SA[0,0,-1],
# 	bottom= SA[0,0,-1],
# 	top	  = SA[0,0,+1],
# 	center= SA[0,0,0],
# )
# @inline labeled_anchor(x::AbstractGeometry{3}, label::Symbol) =
# 	get(default_positions, label, missing)
# @inline labeled_anchor(x::AbstractGeometry{2}, label::Symbol) =
# 	_labeled_anchor_3to2(get(default_positions, label, missing))
# @inline _labeled_anchor_3to2(::Missing) = missing
# @inline _labeled_anchor_3to2(v::StaticVector{3}) =
# # for 2d objects, allow (:left..:right, :bot..:top) as anchor names:
# 	(v[1] == 0 && v[2] == 0 && v[3] != 0) ? SA[v[1], v[3]] : SA[v[1], v[2]]
# # Define named anchors ««2
# # first column is translation, second (if existing) rotation,
# # spin is angle in 2d
# struct AnchorData{D,T,R}
# 	origin::Vec{D,T}
# 	direction::R
# 	spin::T
# 	@inline AnchorData{3,T}(o::AnyVec{3}, r::AnyVec{3}, s::Real) where{T} =
# 		new{3,T,Vec{3,T}}(o, r, s)
# 	@inline AnchorData{2,T}(o::AnyVec{2}, s::Real) where{T} =
# 		new{2,T,Nothing}(o, nothing, s)
# end
# 
# @inline AnchorData{3,T}(v::AnyVec{3}) where{T} =
# 	AnchorData{3,T}(v,SA[0,0,1], zero(T))
# @inline AnchorData{3,T}(data::Tuple{<:AnyVec{3},<:AnyVec{3}}) where{T} =
# 	AnchorData{3,T}(data[1], data[2], zero(T))
# @inline AnchorData{3,T}(data::Tuple{<:AnyVec{3},<:AnyVec{3},<:Real}) where{T} =
# 	AnchorData{3,T}(data[1], data[2], T(radians(data[3])))
# @inline text(x::AnchorData{3}) =
# 	"origin=$(Float64.(x.origin)) direction=$(Float64.(x.direction)) spin=$(Float64(x.spin))"
# 
# @inline AnchorData{2,T}(v::AnyVec{2}) where{T} =
# 	AnchorData{2,T}(v, zero(T))
# @inline AnchorData{2,T}(data::Tuple{<:AnyVec{2},<:Real}) where{T} =
# 	AnchorData{2,T}(data[1], T(radians(data[2])))
# @inline text(x::AnchorData{2}) =
# 	"origin=$(Float64.(x.origin)) angle=$(Float64(x.spin))"
# 
# @inline affine(x::AnchorData) = AffineMap(linear(x), x.origin)
# @inline linear(x::AnchorData{3}) =
# 	rotation_between(SA[0,0,1], x.direction) * RotZ(x.spin)
# @inline rotation(x::AnchorData{2}) = Angle2d(x.spin)
# 
# 
# """
# 		struct NamedAnchors
# 
# Wraps an object, adding symbolic anchors to it.
# """
# struct NamedAnchors{D,T} <: AbstractGeometry{D,T}
# 	child::AbstractGeometry{D,T}
# 	anchors::Dict{Symbol, AnchorData{D,T}}
# end
# """
# 		named_anchors(x, label=>anchor...)
# 
# Adds symbolic anchors to an object. `anchor` may be either
# 
#  - a vector: the associated anchor is a translation.
#  - a pair (origin, direction): the associated anchor is the affine
# 	 rotation to given direction.
#  - a triple (origin, direction, spin).
#  - (in 2d) a pair (origin, angle).
# """
# @inline named_anchors(x::AbstractGeometry{D,T},
# 	a::Pair{Symbol}...) where{D,T} =
# 	NamedAnchors{D,T}(x, Dict(k => AnchorData{D,T}(v) for (k,v) in a))
# 
# function scad(io::IO, x::NamedAnchors, spaces::AbstractString = "")
# 	println(io, spaces, "// Object with named anchors:")
# 	for (label, anchor) in x.anchors
# 		println(io, spaces, "// $label: $(text(anchor))")
# 	end
# 	scad(io, x.child, spaces)
# end
# 
# function labeled_anchor(x::NamedAnchors, label::Symbol)
# 	y = get(x.anchors, label, missing)
# 	if y isa Missing
# 		return get(default_anchors, label, missing)
# 	end
# end
# # Anchors for convex bodies ««2
# """
# 		find_anchor(x::Square, position::SVector{2})
# 		find_anchor(x::Circle, position::SVector{2})
# 		find_anchor(x::Cube, position::SVector{3})
# 		find_anchor(x::Cylinder, position::SVector{3})
# 		find_anchor(x::Sphere, position::SVector{3})
# 
# For a convex body, the anchor corresponding to `position` has its origin
# at the surface fo the body and maps the unit vector `[0,1]` (resp.
# `[0,0,1]` in dimension 3) to the normal vector at this position.
# 
# If `position` is zero, then the translation to the center of the body is
# returned.
# 
# The rotation is computed using `Rotations.rotation_between`. This returns
# a well-defined result even for the rotation mapping `[0,0,1]` to
# `[0,0,-1]`.
# """
# function find_anchor(x::Ortho{D}, pos::Vec{D,<:Real}) where{D}
# 	center = ~x.center*one_half(x.size) # the center of the square/cube
# 	if iszero(pos) return Translation(center) end
# 	maxc = findmax(abs.(pos))[2] # max abs value of a coordinate
# 	v = sum(pos[abs.(pos) .= maxc]), # sum of coordinates with max abs value
# 
# 	# we don't need to normalize v since `rotation_between` does it for us:
# 	AffineMap(rotation_between(SA[0,0,1], v), center + v .* x.size)
# end
# 
# function find_anchor(x::Circle, pos::Vec{2,<:Real})
# 	if iszero(pos) return Translation(SA[0,0]) end
# 	p1 = pos / sqrt(pos[1]^2+pos[2]^2)
# 	AffineMap(SA[p1[2] p1[1]; -p1[1] p1[2]], radius(x)*p1)
# end
# 
# function find_anchor(x::Sphere, pos::Vec{3,<:Real})
# 	if iszero(pos) return Translation(SA[0,0,0]) end
# 	return AffineMap(rotation_between(SA[0,0,1], pos), pos*x.radius / norm(pos))
# end
# 
# function find_anchor(x::Cylinder, pos::Vec{3,<:Real})
# 	center = ~x.center*one_half(x.h)
# 	if iszero(pos) return Translation(center) end
# 	r = sqrt(pos[1]*pos[1]+pos[2]*pos[2]) # convert to cylindrical coords
# 	if pos[3]*x.r2 > r # top face: normalize to pos[3]==1
# 		return Translation(SA[pos[1]/pos[3], pos[2]/pos[3], center+one_half(x.h)])
# 	elseif pos[3]*x.r1 < -r # bottom face: normalize to pos[3]==-1
# 		return AffineMap(rotation_between(SA[0,0,1], SA[0,0,-1]),
# 			SA[-pos[1]/pos[3], -pos[2]/pos[3], center-one_half(x.h)])
# 	end
# 	# the line equation is 2r = (r2-r1) z + (r1+r2)
# 	r3 = one_half(x.r1+x.r2+pos[3]*(x.r2-x.r1)) # radius at given z
# 	# in cyl coordinates, the contact point is (r=r3, z=pos[3]*h/2+center)
# 	p = SA[pos[1]*r3/r, pos[2]*r3/r, center + one_half(x.h)*pos[3]]
# 	# normal vector is 2 dr = (r2-r1) dz
# 	n = SA[2*pos[1]/r, 2*pos[2]/r, x.r2-x.r1]
# 	AffineMap(rotation_between(SA[0,0,1], n), p)
# end
# 
# # Coordinates on circle & sphere ««2
# """
# 		find_anchor(x::Circle, angle::Real)
# Returns anchor at point `(-sin(angle), cos(angle))` (trig. orientation,
# starting at top of circle; angle in **degrees**) with outwards normal vector
# (the start at top guarantees that angle 0 preserves upwards-pointing
# vector).
# """
# function find_anchor(x::Circle{T}, angle::Real) where{T}
# # 	a = T(radians(angle))
# 	(s, c) = T.(sincosd(a))
# 	AffineMap(SA[c -s;s c], SA[-radius(x)*s, radius(x)*c])
# end
# """
# 		find_anchor(x::Sphere, (latitude, longitude))
# 
# Returns normal vector to sphere at this position (angles in **degrees**).
# """
# function find_anchor(x::Sphere{T}, angle::AnyVec{2,<:Real}) where{T}
# # 	(lat, lon) = T.(radians.(angle))
# 	(s1, c1) = T.(sincosd(lat))
# 	(s2, c2) = T.(sincosd(lon))
# 	r = x.radius
# 	AffineMap(SA[s1*c2 -s2 c1*c2;s1*s2 c2 c1*s2; -c1 0 s1],
# 						SA[r*c1*c2, r*c1*s2, r*s1])
# end
# 
# 
# # attach ««2
# """
# 		attach(parent, {:label => child}...)
# 
# Moves (by rotations) all children so that their anchor matches the
# anchors of `parent` defined by the given labels.
# """
# function attach(parent::AbstractGeometry, list::Pair{<:Any,<:AbstractGeometry}...)
# 	union(parent, [ attach_at(parent, pos, child) for (pos,child) in list]...)
# end
# function attach_at(parent::AbstractGeometry{D}, label, child::AbstractGeometry) where{D}
# 	m = find_anchor(parent, label)
# 	mult_matrix(m, child)
# end
# 
# # anchor ««2
# """
# 		half_turn(q::UnitQuaternion)
# 
# Returns the half-turn rotation with same axis as `q`.
# """
# @inline half_turn(q::Rotations.UnitQuaternion) =
# 	Rotations.UnitQuaternion(0, q.x, q.y, q.z) # the constructor normalizes this
# """
# 		half_turn_complement(q::Rotation{3})
# 
# Returns the unique rotation `r` such that `qr=rq` is a half-turn.
# """
# @inline half_turn_complement(q::Rotations.Rotation{3}) =
# 	inv(q)*half_turn(q)
# 
# """
# 		anchor(solid, label)
# 
# Translates the solid so that the anchor with name `label` is at origin
# and the corresponding anchor vector points inward.
# """
# function anchor(x::AbstractGeometry, label)
# # Ax + B maps [0,0,0] to anchor point p, and e_z=[0,0,1] to anchor vec v
# # namely: A e_z = v, B = p
# # we want to map p to [0,0,0] and -v to e_z
# # i.e. A' v = - e_z and A' p + B' = 0, or B' = -A' p = -A' B
# #
# 
# 	m = find_anchor(x, label)
# 	a1= half_turn_complement(linear(m))
# # ⚠ -a1*m is interpreted as (-a1)*m, and a1 is a quaternion ⇒ -a1≡a1 (as
# # a rotation)
# 	mult_matrix(AffineMap(a1, a1*-translation(m)), x)
# end
# 
# # Reduction of mult_matrix operations ««1
# @inline affine_reduce(m::AbstractAffineMap, x::AbstractGeometry) =
# 	mult_matrix(m, x)
# @inline affine_reduce(u::LinearMap{<:Diagonal}, x::Square) =
# 	Square([ u.linear.diag[i] * @inbounds x.size[i] for i in 1:2 ], x.center)
# @inline affine_reduce(u::LinearMap{<:Union{UniformScaling,Diagonal}},
# 	x::Union{Square,Cube}) = (typeof(x))(linear(u) * x.size, x.center)
# @inline affine_reduce(u::LinearMap{<:UniformScaling},
# 	x::Union{Circle,Sphere}) =
# 	(typeof(x))(linear(u) * x.r, x.frag)
# @inline affine_reduce(u::AbstractAffineMap, x::Polygon) =
# 	Polygon(apply(u, vertices(x)), x.path, x.convexity)
# @inline affine_reduce(u::AbstractAffineMap, x::Surface) =
# 	Surface(apply(u, vertices(x)), x.faces, x.convexity)
# @inline affine_reduce(m::AbstractAffineMap, x::T) where{T<:ConstructedSolid} =
# 	T([ affine_reduce(m, y) for y in children(x) ])
# function affine_reduce(m1::AbstractAffineMap, m2::MultMatrix)
# 	m3 = compose(m1, m2.m)
# 	union((affine_reduce(m3, x) for x in children(m2))...)
# 	# TODO
# end
# affine_reduce(x::AbstractGeometry) = affine_reduce(LinearMap(I), x)
#————————————————————— Meshing —————————————————————————————— ««1
#»»1
# Converting circles to polygons««1
# Accuracy is the absolute deviation allowed.
# Default value is 2.0 (from OpenSCAD `$fs`), interpreted as 2mm.
#
# Precision is the relative deviation allowed.
# Default value is 0.02 (1-cos(180°/`$fa`)).

_DEFAULT_PARAMETERS = (accuracy = 2.0, precision = .02)

"""
    sides(radius, parameters, θ = 360°)

Returns the number of sides used to draw a circle (arc) of given angle.
The base value `n` is given by the minimum of:
 - accuracy: each side (length `θ r/n`) must not be smaller than accuracy,
   or n = θ r / accuracy;
 - precision: deviation=1/cos(θ/2n)≈ θ²/8n²,
	 or n ≈ θ/√(8 * precision)
"""
function sides(r::Real, parameters::NamedTuple, angle::AnyAngle = 360°)
	θ = radians(angle)
	acc = ceil(Int, θ*r / (parameters.accuracy))
	pre = ceil(Int, θ/sqrt(8*parameters.precision))
	base = min(acc, pre)
	# a circle always has at least 4 sides
	return max(4, base)
end
"""
    sphere_vertices(r::Real, parameters::NamedTuple)

Returns the number `n` of points on a sphere according to these
parameters.

This produces n points on the sphere, hence 2n-4 triangular faces
(genus 0). Average surface of a triangular face is 4πr²/(2n-4)=2πr²/(n-2),
hence square of edge length is d²≈ 8πr²/√3/(n-2).
(unit equilateral triangle s = √3d²/4, i.e. d²=4s/√3).

* each edge length `d` must not be smaller than accuracy `α`:
  namely 8πr²/√3/(n-2) ≥ α², or n ≤ (8π/√3) (r/α)² + 2.
* each error (sagitta) must not be smaller than `r*ε`, where ε = precision;
  sagitta formula: σ/r = 1-√(1-d²/4r²) = 1-√(1-(2π/√3)/(n-2)).
  ∼ (π/√3)/(n-2) + O(n-2)^-2;
  hence  n ≤ 2 + (π/√3)/ε.
"""
function sphere_vertices(r::Real, parameters::NamedTuple)
	n_acc = ceil(Int, 2 + (8π/√3)*(r/parameters.accuracy)^2)
	n_pre = ceil(Int, 2 + (π/√3)/parameters.precision)
	# a sphere always has at least 6 vertices
	return max(6, min(n_acc, n_pre))
end


"""
    unit_n_gon(T::Type, n::Int)
		unit_n_gon(r, n)

Returns the vertices of a regular n-gon inscribed in the unit circle
as points with coordinates of type `T`, while avoiding using too many
trigonometric computations.
"""
function unit_n_gon(T::Type{<:Real}, n::Int)
	ω = cis(2π/n) # exp(2iπ/n)
	z = Vector{Complex{T}}(undef, n)
	z[1] = one(T)
	# TODO: use 2-fold, 4-fold symmetry if present
	# n=3: 2..2
	# n=4: 2..2 (+ point 3 = -1)
	# n=5: 2..3
	# n=6: 2..3 (+ point 4 = -1)
	# points with y>0:
	for i in 2:(n+1)>>1
		@inbounds z[i] = z[i-1]*ω; z[i] /= abs(z[i]) # for radius stability
		# z[n] = conj(z[2]), etc.
		@inbounds z[n+2-i] = conj(z[i])
	end
	if iseven(n)
		@inbounds z[n>>1+1] = -1
	end
	reinterpret(Vec{2,T}, z)
end
@inline unit_n_gon(r, parameters) =
	r*unit_n_gon(real_type(r), sides(r, parameters))

const golden_angle = 2π/MathConstants.φ
"""
    fibonacci_sphere_points(T::Type{<:Real}, n::Int)

Returns a set of `n` well-spaced points, of type `Vec{3,T}`, on the unit
sphere.

TODO: use ideas from
http://extremelearning.com.au/evenly-distributing-points-on-a-sphere/

to optimize for volume of convex hull.
"""
function fibonacci_sphere_points(T::Type{<:Real}, n::Int)

	v = Vector{Vec{3,T}}(undef, n)
	for i in eachindex(v)
		θ = i*T(golden_angle)
		z = (n+1-2i)/T(n)
		ρ = √(1-z^2)
		(s,c) = sincos(θ)
		@inbounds v[i] = SA[c*ρ, s*ρ, z]
	end
	return v
end
@inline fibonacci_sphere_points(r::Real, parameters) =
	r*fibonacci_sphere_points(real_type(r),
		sphere_vertices(r, parameters))

# Clipper.jl interface: clip, offset, simplify««1
# This is the only section in this file which contains code directly
# related to `Clipper.jl`. The entry points to this section are the
# functions `clip` and `offset` defined below.
# Types««2
# default number of bits for Clipper types
const _CLIPPER_BITS = FixedPointNumbers.nbitsfrac(_FIXED)
# this must be a 64-bit type, even if _FIXED is modified:
const _CLIPPER_FIXED = Fixed{Int64,_CLIPPER_BITS}
# constants
const _CLIPPER_ENUM = (#««
	clip=(
		union       =Clipper.ClipTypeUnion,
		intersection=Clipper.ClipTypeIntersection,
		difference  =Clipper.ClipTypeDifference,
		xor         =Clipper.ClipTypeXor,
	),
	ends=(
		closed=Clipper.EndTypeClosedPolygon,
		square=Clipper.EndTypeOpenSquare,
		round =Clipper.EndTypeOpenRound,
		butt  =Clipper.EndTypeOpenButt,
	),
	join=(
		square=Clipper.JoinTypeSquare,
		round =Clipper.JoinTypeRound,
		miter =Clipper.JoinTypeMiter,
	),
	fill=(
		nonzero=Clipper.PolyFillTypeNonZero,
		evenodd=Clipper.PolyFillTypeEvenOdd,
		positive=Clipper.PolyFillTypePositive,
	),
)#»»

"""
    to_clipper(OriginalType, ...)
		from_clipper(OriginalType, ...)

Converts stuff (numbers, vectors, paths...) to and from `Clipper.jl` types.
"""
@inline to_clipper(::Type{<:Real}) = _CLIPPER_FIXED
@inline to_clipper(T::Type{<:FixedPoint{<:Int64}}) = T
@inline to_clipper(T::Type, x::Real) = reinterpret(convert(to_clipper(T), x))
@inline to_clipper(T::Type, v::Point{2,<:Real}) =
	Clipper.IntPoint(to_clipper(T, v[1]), to_clipper(T, v[2]))
@inline to_clipper(T, p::AbstractVector{<:Point{2}}) =
	[to_clipper(T, v) for v in p]
@inline to_clipper(T, p::Vector{<:AbstractVector{<:Point{2}}}) =
	[to_clipper(T, v) for v in p]

# special case: if the data is already compatible, we just wrap it
@inline to_clipper(::Type{T}, p::Path{2,T}) where{T<:FixedPoint{<:Int64}} =
	GC.@preserve p unsafe_wrap(Array,
		pointer(reinterpret(Clipper.IntPoint, p)),
		length(p))
# FIXME: in the general case, check stride of array

# this is a special case; the `delta` parameter wants a Float64,
# and we *might* use a different type for `delta` than for coordinates:
@inline to_clipper_float(T::Type{<:Real}, x)::Float64 =
	x*FixedPointNumbers.rawone(to_clipper(T))

# numbers...
@inline from_clipper(T::Type{<:Real}, x::Int64) =
	convert(T, reinterpret(to_clipper(T), x))
# points...
@inline from_clipper(T::Type{<:Real}, p::Clipper.IntPoint) =
	Point{2}(SA[from_clipper(T, p.X), from_clipper(T, p.Y)])
# paths...
@inline from_clipper(T::Type{<:Real}, p::Vector{Clipper.IntPoint}) =
	[ from_clipper(T, v) for v in p ]
@inline from_clipper(T::Type{<:Fixed{Int64}}, p::Vector{Clipper.IntPoint}) =
	reinterpret(Vec{2,T}, p)
# vectors of paths...
@inline from_clipper(T, polys::Vector{Vector{Clipper.IntPoint}}) =
	[ from_clipper(T, p) for p in polys ]
# Wrappers for Clipper calls««2
# We wrap all Clipper objects in a NamedTuple with the original type
struct Marked{T,X}
	data::X
	@inline Marked{T}(x::X) where{T,X} = new{T,X}(x)
end

@inline ClipperClip(T::Type) = Marked{T}(Clipper.Clip())
@inline ClipperOffset(T::Type, miterLimit::Real, roundPrecision::Real) =
	Marked{T}(Clipper.ClipperOffset(Float64(miterLimit),
		to_clipper_float(T, roundPrecision)))

@inline add_path!(c::Marked{T}, path::AnyPath{2}, args...) where{T} =
	Clipper.add_path!(c.data, to_clipper(T, path), args...)
@inline add_paths!(c::Marked{T}, paths::Vector{<:AnyPath{2}}, args...) where{T}=
	Clipper.add_paths!(c.data, [ to_clipper(T, p) for p in paths], args...)

@inline execute(c::Marked{T,Clipper.Clip}, args...) where{T} =
	from_clipper(T, Clipper.execute(c.data, args...)[2])
@inline execute(c::Marked{T,Clipper.ClipperOffset}, delta::Real) where{T} =
	from_clipper(T, Clipper.execute(c.data, to_clipper_float(T, delta)))

# Calls on Path values««2
function clip(op::Symbol,
		v1::AbstractVector{Path{2,T}},
		v2::AbstractVector{Path{2,T}};
		fill = :positive)::Vector{Path{2,T}} where {T}
	c = ClipperClip(T)
	add_paths!(c, v1, Clipper.PolyTypeSubject, true) # closed=true
	add_paths!(c, v2, Clipper.PolyTypeClip, true)

	f = _CLIPPER_ENUM.fill[fill]
	return execute(c, _CLIPPER_ENUM.clip[op], f, f)
end
function offset(v::AbstractVector{Path{2,T}}, r::Real;
		join = :round,
		ends = :closed,
		miter_limit = 2.,
		precision = 0.2
		)::Vector{Path{2,T}} where{T}
	c = ClipperOffset(T, miter_limit, precision)
	add_paths!(c, v, _CLIPPER_ENUM.join[join], _CLIPPER_ENUM.ends[ends])
	execute(c, r)
end
function offset(v::AbstractVector{Path{2,T}}, r::AbstractVector{<:Real};
		join = :round,
		ends = :closed,
		miter_limit = 2.,
		precision = 0.2
		)::Vector{Vector{Path{2,T}}} where{T}
	# “Simultaneously” computes offset for several offset values.
	# Used by path_extrude() below.
	c = ClipperOffset(T, miter_limit, precision)
	add_paths!(c, v, _CLIPPER_ENUM.join[join], _CLIPPER_ENUM.ends[ends])
	[ execute(c, ρ) for ρ in r]
end
@inline function simplify(p::Vector{<:AnyPath{2,T}}; fill=:nonzero) where{T}
	return from_clipper(T,
		Clipper.simplify_polygons(to_clipper(T, p), _CLIPPER_ENUM.fill[fill]))
end
"""
    orientation(p::Path{2})

Returns `true` iff p is a direct loop (i.e. if area >= 0).
"""
@inline function orientation(p::Path{2,T}) where{T}
	return Clipper.orientation(to_clipper(T, p))
end
"""
    pointinpolygon(pt::Vec{2}, p::Path{2})

Returns 1 if point is in the interior, -1 on boundary, and 0 outside the
given polygon.

Polygon is assumed not self-intersecting.
"""
@inline function point_in_polygon(point::Point{2,T},
	path::AnyPath{2,T}) where{T}
	return Clipper.pointinpolygon(to_clipper(T, point), to_clipper(T, path))
end
# Polyhedra interface««1
@inline polyhedra_lib(T::Type{<:Real}) =
	Polyhedra.DefaultLibrary{T}(GLPK.Optimizer)

# converts path to matrix with points as rows:
@inline poly_vrep(points::AnyPath) = vcat(transpose.(Vector.(points))...)
@inline poly_vrep(points::Matrix) = points
@inline poly_eltype(points::AnyPath) = eltype(eltype(points))
@inline poly_eltype(points::Matrix) = eltype(points)
"""
    vpoly(points...)

Returns a `Polyhedra.polyhedron` in vrep from a list of points.
"""
@inline function vpoly(points; lib=true)
	PH = Polyhedra
	if lib
		return PH.polyhedron(PH.vrep(poly_vrep(points)),
			polyhedra_lib(poly_eltype(points)))
	else
		return PH.polyhedron(PH.vrep(poly_vrep(points)))
	end
end

# HRepElement is the supertype of HalfSpace and HyperPlane
@inline direction(h::Polyhedra.HRepElement) = h.a
@inline (h::Polyhedra.HRepElement)(p::Point) = h.a ⋅ p - h.β
@inline ∈(p::Point, h::Polyhedra.HyperPlane) = iszero(h(p))
@inline convert(T::Type{<:Polyhedra.HRepElement}, h::Polyhedra.HRepElement) =
	T(h.a, h.β)

# we need a couple of functions in the particular case of simplexes.
# `Polyhedra.jl` is a bit slow for these simple cases, so we write them
# here:

regularize(x::Float64) = (x == -0.0) ? 0.0 : x
"""
    inter(path, hyperplane::Polyhedra.HyperPlane)

    intersection of simplex and hyperplane
"""
function inter(path::AnyPath, hyperplane::Polyhedra.HyperPlane)
	n = length(path)
	s = [hyperplane(p) for p in path]
	newpath = similar(path, n); c = 0
	for i in 1:n
		if s[i] == 0
			newpath[c+= 1] = path[i]
		end
		for j in 1:i-1
			if s[i] * s[j] < 0
				newpath[c+= 1] = regularize.((s[j]*path[i]-s[i]*path[j])/(s[j]-s[i]))
			end
		end
	end
	return newpath[1:c]
end
"""
    inter(path, halfplane)

Computes intersection of a (planar) convex closed loop and the half-plane [h≥0].
The intersection is returned as a vector of points.
"""
function inter(path::AnyPath, halfplane::Polyhedra.HalfSpace)
	s = [halfplane(p) for p in path]
	boundary = convert(Polyhedra.HyperPlane, halfplane)
	n = length(path)
	# we know that we add at most 1 new point (cutting a corner).
	newpath = similar(path, n+1); c = 0
	for i in eachindex(path)
		j = mod1(i+1, n)
		(si, sj) = (s[i], s[j])
		if si >= 0   newpath[c+=1] = path[i]; end
		if si*sj < 0
		# whiskers would generate two new points; we remove the second one
			newpoint = inter(path[[i,j]], boundary)[1]
			if (c==0|| newpath[c] != newpoint) newpath[c+=1] = newpoint; end
		end
	end
	return newpath[1:c]
end
@inline inter(path::AnyPath, h::Polyhedra.HRepElement,
		t::Polyhedra.HRepElement...) =
	inter(inter(path, h), t...)

"""
    line(p1=>p2)
"""
# XXX
function line(p12::Pair{<:Point{2}})
	(x1, y1) = p12[1]
	(x2, y2) = p12[2]
	a = SA[y1-y2, x2-x1]
	b = y1*x2 - x1*y2
	return Polyhedra.HyperPlane(a, b)
end
"""
    halfplane(p1=>p2, p3)

Returns the half-plane through (p1, p2) such that h(p3) > 0.
"""
function halfplane(p12::Pair{<:Point{2}}, p3::Point{2})
	l = line(p12)
# 	(x1, y1) = p12[1]
# 	(x2, y2) = p12[2]
# 	a = SA[y1-y2, x2-x1]
# 	b = y1*x2 - x1*y2
	s = sign(l.a ⋅ p3 - l.β)
	return Polyhedra.HalfSpace(s*l.a, s*l.β)
end

"""
    hrep(pt1, pt2, pt3)

Returns the triple of half-planes delimiting the interior of the given
triangle.
"""
function hrep(p1::Point{2}, p2::Point{2}, p3::Point{2})
	return (halfplane(p1=>p2, p3),
	        halfplane(p2=>p3, p1),
	        halfplane(p3=>p1, p2))
end

Segment{D,T} = GeometryBasics.Simplex{D,T,2,Point{D,T}}
function line_inter(s1::Segment{2}, s2::Segment{2})
	((x1,y1), (x2,y2)) = vertices(s1)
	((x3,y3), (x4,y4)) = vertices(s2)
	d=(x1-x2)*(y3-y4)-(y1-y2)*(x3-x4)
	if iszero(d) return nothing; end
	a = x1*y2-y1*x2; b = x3*y4-y3*x4
	d1 = inv(to_real(d))
	return Point(d1 .* SA[a*(x3-x4)-b*(x1-x2), a*(y3-y4)-b*(y1-y2)])
end
function inter(s1::Segment{2}, s2::Segment{2})
	c = line_inter(s1, s2)
	if c isa Nothing return nothing; end
	if c ∈ boundingbox(s1) return c; end
	return nothing
end
function inter(s1::Segment{3}, s2::Segment{3})
	(a1, b1) = vertices(s1)
	(a2, b2) = vertices(s2)
	d = det3(a1, b1, a2, b2)
	# check all points are coplanar
	if !iszero(d)
		return nothing
	end
	# compute supporting plane
	plane = supporting_plane(Triangle(a1, b1, a2))
	(proj, lift) = project_2d(plane)
	int2 = inter(Segment(Point(a1[proj]),Point(b1[proj])),
		Segment(Point(a2[proj]),Point(b2[proj])))
	if int2 == nothing
		return nothing
	end
	return lift(int2)
end


# Operations on simplicial complexes««1
# Incidence and adjacency««2
"""
    adjacency_points(s::AbstractSurface)

Returns the adjacency matrix on points of s, indexed by entries of
`vertices(s)`.
"""
@inline adjacency_points(s::AbstractSurface) =
	adjacency_points(vertices(s), faces(s))
function adjacency_points(points, faces)
	n = length(points)
	m = spzeros(Bool,n, n)
	for f in faces
		for i in 1:length(f), j in 1:i-1
			m[f[i],f[j]] = m[f[j],f[i]] = true
		end
	end
	return m
end

"""
    edge_can

Puts an edge in canonical form. Returns `(sign, canonical)`,
where the boolean is `true` if the edge was reversed.
"""
@inline edge_can(e) =
	(e[1] < e[2]) ? (false, SA[e[1],e[2]]) : (true, SA[e[2],e[1]])
# this must return an array because we use array[array] shorthand
"""
    incidence(s::AbstractSurface)

Returns an incidence and ajacency structure for the simplicial complex s.
This returns a named tuple with fields:
 - `points`: adjacency for points;
 - `faces`: adjacency for faces;
 - `edge_faces`: incidence edge -> face;
 - `point_faces`: incidence point -> face;
"""
function incidence(s::AbstractSurface;
		vf=true, ef=true, ff=true)
  inc_pf = [Int[] for p in vertices(s)]
	# face adjacency needs edge-face:
	ef = ef||ff
	if vf
		for (i, f) in pairs(faces(s)), p in f
			push!(inc_pf[p], i)
		end
	end
	inc_ef = Dict{SVector{2,Int}, Vector{Int}}()
	if ef
		for (i, f) in pairs(faces(s)), u in 1:3
			e = (f[u], f[plus1mod3[u]])
			(b, c) = edge_can(e)
			if !haskey(inc_ef, c) inc_ef[c] = []; end
			push!(inc_ef[c], b ? -i : i)
		end
	end
	inc_ff = [Int[] for f in faces(s)]
	if ff
		for a in values(inc_ef), i in eachindex(a), j in 1:i-1
			(f, g) = abs(a[i]), abs(a[j])
			push!(inc_ff[f], g)
			push!(inc_ff[g], f)
		end
	end

	return (
		point_faces = inc_pf,
		edge_faces = inc_ef,
		faces = inc_ff,
	)
end

# """
#     regular_components(s::AbstractSurface,
# 			cc
# 
# Returns the set of connected components of faces of `s`, for the
# edge-adjacency relation restricted to binary edges.
# 
# """
# function regular_components(s::AbstractSurface;
# 	edge_faces = incidence(s; vf=false, ff=false).edge_faces)
# 	n = nfaces(s)
# 	m = spzeros(Bool,n,n)
# 	for (e, a) in pairs(edge_faces)
# 		if length(a) == 2
# 			i = abs.(a)
# 			println("adjacent: $a")
# 			m[i[1],i[2]] = m[i[2],i[1]] = true
# 		end
# 	end
# 	g = LightGraphs.SimpleGraph(m)
# 	cc = LightGraphs.connected_components(g)
# 	return cc
# end

@inline copy(s::AbstractSurface) = (typeof(s))(vertices(s), faces(s))

# Merging and selecting««2
"""
    merge(s1::AbstractSurface, s2::AbstractSurface)

Combines both triangulations, renumbering points of `s2` as needed.
(Numbering in `s1` is preserved).
"""
function merge(s1::AbstractSurface, s2::AbstractSurface, same = ==)
	renum = Vector{Int}(undef, nvertices(s2))
	# renumber points:
	p1 = nvertices(s1)
	p2 = nvertices(s2)
	newpoints = similar(vertices(s1), p1+p2)
	newpoints[1:p1] = vertices(s1)
	idx = p1
	for (i, p) in pairs(vertices(s2))
		k = findfirst(same(p), newpoints)
		if k == nothing
			newpoints[idx+=1] = p
			renum[i] = idx
		else
			renum[i] = k
		end
	end
	resize!(newpoints, idx)

	# relabel faces
	f1 = nfaces(s1)
	f2 = nfaces(s2)
	newfaces = similar(faces(s1), f1+f2)
	newfaces[1:f1] = faces(s1)
	for (i, f) in pairs(faces(s2))
		newfaces[f1+i] = renum[f] # array indexed by array trick
	end

	return surface(newpoints, newfaces)
end

"""
    select_faces(f, s::AbstractSurface)
    select_faces(list, s::AbstractSurface)

Returns the subcomplex containing only the faces `i` for which `f(i)`
evaluates to a true value. Points are renamed.
"""
function select_faces(list::AbstractVector{<:Integer}, s::AbstractSurface)
	renum = fill(0, eachindex(vertices(s)))
	newfaces = SVector{3,Int}[]
	newpoints = similar(vertices(s))
	n = 0
	for i in list
		if i > 0
			f = faces(s)[i]
		else
			f = reverse(faces(s)[-i])
		end
		for p in f
			if renum[p] == 0
				renum[p] = (n+= 1)
				newpoints[n] = vertices(s)[p]
			end
		end
		push!(newfaces, renum[f])
	end
	resize!(newpoints, n)
	return (typeof(s))(
		newpoints,
		remove_opposite_faces(newfaces))
end
@inline select_faces(test::Function, s::AbstractSurface) =
	select_faces(filter(test,eachindex(faces(s))), s)

# """
#     connected_components(s::AbstractSurface)
# 
# Returns a vector of objects (same type as `s`), each one of which is a
# (renumbered) connected component.
# """
# @inline connected_components(s::AbstractSurface) =
# 	[ typeof(s)(p,f)
# 		for (p,f) in connected_components(vertices(s), faces(s)) ]
# function connected_components(points, faces)
# 	# Build the incidence matrix from the list of faces
# 	N = length(points)
# 	G = LightGraphs.SimpleGraph(adjacency_points(points, faces))
# 	C = LightGraphs.connected_components(G)
# 	# C is a vector of vector of indices
# 	# newindex[oldindex] = [component, new index]
# 	component = zeros(Int, N)
# 	newindex = zeros(Int, N)
# 	for (i, c) in pairs(C)
# 		for (j, p) in pairs(c)
# 			component[p] = i
# 			newindex[p] = j
# 		end
# 	end
# 	return [ (typeof(s))(
# 		# all points in component i
# 		points[filter(p->component[p] == i, 1:N)],
# 		[ [newindex[p] for p in f] for f in faces if component[f[1]] == i ]
# 		) for i in eachindex(C) ]
# end

# Manifoldness test««2
"""
    ismanifold(s::AbstractSurface)

Returns `(value, text)`, where `value` is a Bool indicating whether this
is a manifold surface, and `text` explains, if this is not manifold,
where the problem lies.
"""
function ismanifold(s::AbstractSurface)
	# TODO: check that triangles do not intersect
	inc = incidence(s) # needed here: vf, ef, ff
	for (e, f) in pairs(inc.edge_faces)
		if length(f) != 2
			# edge adjacent to wrong number of faces
			return (value=false, text=(:singular_edge, e, f))
		end
		# check orientability; we stored orientation in the sign bit, this
		# simplifies the following code **a lot**:
		if f[1]*f[2] > 0
			# incompatible orientations for both faces
			return (value=false, text=(:not_orientable, e, f))
		end
	end
	for (p, flist) in pairs(inc.point_faces)
		adj = [ flist ∩ inc.faces[f] for f in flist ]
		for (i, a) in pairs(adj)
			if length(a) != 2
				# face adjacent to wrong number of faces around this vertex
				return (value=false, text=(:vertex_faces_adj, p, flist[i], a))
# 					text="vertex $p: face $(flist[i]) adjacent to $(length(a)) other faces ($a)")
			end
		end
		# we need to check that all these adjacent faces form a simple loop.
		# This is easy to do by checking connectedness of the graph:
		c = falses(length(flist)); c[1] = true; n = 1
		rev = Dict{Int,Int}()
		for (u,v) in pairs(flist) rev[v] = u; end
		while n > 0
			n = 0
			for i in vcat(adj[c]...)
				if !c[rev[i]] c[rev[i]] = true; n+= 1; end
			end
		end
		if(!all(c))
			# faces around this vertex do not form a simple loop
			return (value=false, text=(:singular_vertex, p,
				[flist[i]=>adj[i] for i in eachindex(flist)]))
# 			return (value=false, text="faces around vertex $p do not forc a connected graph: $([flist[i] => adj[i] for i in eachindex(flist)])")
		end
	end
	return (value=true, text="is manifold")
end

# # DirectedEdgesTriMesh««1
# # Utilities««2
# # struct DictOfList{A,B}
# # 	data::Dict{A,Vector{B}}
# # end
# # @inline keytype(::Type{DictOfList{A,B}}) where{A,B} = A
# # @inline valtype(::Type{DictOfList{A,B}}) where{A,B} = B
# # @inline keytype(d::DictOfList) = keytype(typeof(d))
# # @inline valtype(d::DictOfList) = valtype(typeof(d))
# # 
# # function Base.push!(d::DictOfList, key, value)
# # 	if !haskey(d.data, key) d.data[key] = valtype(d)[]; end
# # 	return push!(d.data[key], value)
# # end
# # @inline Base.getindex(d::DictOfList, key) = getindex(d.data, key)
# 
# # Basic types««2
# struct DirectedEdgesTriMesh{T}
# 	opposite::Vector{Int} # 3×n
# 	destination::Vector{Int}
# 	from::T # Vector or Dict
# 	@inline DirectedEdgesTriMesh(;opposite, destination, from) =
# 		new{typeof(from)}(opposite, destination, from)
# end
# 
# function DirectedEdgesTriMesh(
# 		faces::AbstractVector{<:AbstractVector{<:Integer}})
# 	@assert all(length.(faces) .== 3)
# 	# vf[p] = [faces containing point p]
# 	points = union(faces...)
# 	vf = Dict(p=>Int[] for p in points)
# 	from = Dict(p=>0 for p in points)
# # 	from = Vector{Int}(undef, length(points))
# 	# face i has 3i-2..3i
# 	for (i, f) in pairs(faces), (j, p) in pairs(f[1:3])
# 		push!(vf[p], i)
# 		from[p] = 3*i-3+j
# 	end
# 	function find_edge(p, q)#««
# 	# returns index of edge pq (in this direction)
# 		for i in vf[p]
# 			f = faces[i]
# 			if f[1]==p && f[2]==q return 3*i-2
# 			elseif f[2]==p && f[3]==q return 3*i-1
# 			elseif f[3]==p && f[1]==q return 3*i
# 			end
# 		end
# 		return 0 # opposite edge not found: we are on the boundary
# 		# (e.g. when dissecting a triangle)
# 	end#»»
# 	opposite = Vector{Int}(undef, 3*length(faces))
# 	destination=Vector{Int}(undef, 3*length(faces))
# 	for (i, f) in pairs(faces)
# 		destination[3*i-2] = f[2]
# 		destination[3*i-1] = f[3]
# 		destination[3*i  ] = f[1]
# 		opposite[3*i-2] = find_edge(f[2], f[1])
# 		opposite[3*i-1] = find_edge(f[3], f[2])
# 		opposite[3*i  ] = find_edge(f[1], f[3])
# 	end
# 	return DirectedEdgesTriMesh(;
# 		opposite=opposite,
# 		destination=destination,
# 		from=from)
# end
# 
# @inline next(::DirectedEdgesTriMesh, n) = n+1-3*(n%3==0)
# @inline prev(::DirectedEdgesTriMesh, n) = n-1+3*(n%3==1)
# @inline nfaces(m::DirectedEdgesTriMesh) = fld(length(m.opposite),3)
# # @inline vertices(m::DirectedEdgesTriMesh) = m.points
# @inline opposite(m::DirectedEdgesTriMesh, ab) = m.opposite[value(ab)]
# @inline opposite!(m::DirectedEdgesTriMesh, ab, x) =
# 	m.oposite[value(ab)] = x
# @inline destination(m::DirectedEdgesTriMesh, ab) = m.destination[value(ab)]
# @inline destination!(m::DirectedEdgesTriMesh, ab, x) =
# 	m.destination[value(ab)] = x
# @inline from(m::DirectedEdgesTriMesh, pt) = m.from[pt]
# @inline from!(m::DirectedEdgesTriMesh, pt, x) = m.from[pt] = x
# 
# # @inline function new_half_edges(m:::DirectedEdgesTriMesh, n::Integer)
# # 	l = length(m.opposite)
# # 	resize!(m.opposite, l+n)
# # 	resize!(m.destination, l+n)
# # 	return (l+1:l+n)
# # end
# 
# @inline destination(m::DirectedEdgesTriMesh, ab) = m.destination[value(ab)]
# 
# struct DirectedEdgesTriFaces <: AbstractVector{SVector{3,Int}}
# 	mesh::DirectedEdgesTriMesh
# end
# @inline Base.size(itr::DirectedEdgesTriFaces) = (nfaces(itr.mesh),)
# @inline Base.getindex(itr::DirectedEdgesTriFaces, n::Integer) =
# 	SVector{3,Int}(view(itr.mesh.destination, 3*n-2:3*n))
# @inline faces(m::DirectedEdgesTriMesh) = DirectedEdgesTriFaces(m)
# 
# # Splitting edges and faces««2
# """
#     split_edge!(m::DirectedEdgesTriMesh, ab, p)
# 
# Inserts points `p` in the middle of the half-edge `ab` and its opposite.
# """
# function split_edge!(m::DirectedEdgesTriMesh, ab, pt::Point{3})
# 	n = nfaces(m)
# 	# Grab all the edge and vertex info from structure
# 	bc = next(m, ab); ca = next(m, ab)
# 	cb = opposite(m, bc); ac = opposite(m, ca)
# 	ba = opposite(m, ab); ad = next(m, ba); db = next(m, ad)
# 	da = opposite(m, ad); bd = opposite(m, db)
# 	# use the inner half-edges for computing destination:
# 	# (outer half-edges might not be defined if we have a boundary...)
# 	b = destination(m, ab); a = destination(m, ba)
# 	c = destination(m, bc); d = destination(m, ad)
# 	# Define new values for point x and triangles xbc, xad
# 	push!(m.points, pt);
# 	x = length(m.points)
# 	resize!(m.halfedges, 3*n+6)
# 	xb = 3*n+1; new_bc = 3*n+2; cx = 3*n+3
# 	xa = 3*n+4; new_ad = 3*n+5; dx = 3*n+6
# 	push!(m.from, xb)
# 	# adjust structure to record all values
# 	@inline set!(edge, dest, opp) = (
# 		m.destination[edge] = dest; m.opposite[edge] = opp; )
# 	# triangle axc
# 	ax = ab; set!(ax, x, xa)
# 	xc = bc; set!(xc, c, cx) # here we overwrite `c` by `c`...
# 	# ca unchanged
# 	# triangle bxd
# 	bx = ba; set!(bx, x, xb)
# 	xd = ad; set!(xd, d, dx) # ditto
# 	# db unchanged
# 	# triangle xbc
# 	set!(xb, b, bx); set!(new_bc, c, cb); set!(cx, x, xc)
# 	# triangle xad
# 	set!(xa, a, ax); set!(new_ad, d, da); set!(dx, x, xd)
# 	return m # or x...
# end
#Convex hull««1
# 2d convex hull ««2

# """
#     convex_hull([vector of 2d points])
# 
# Returns the convex hull (as a vector of 2d points).
# """
# function convex_hull(points::Union{AbstractVector{<:Vec{2}},
# 	AbstractMatrix{<:Number}})
# # M is a matrix with the points as *columns*, hence the transpose
# # below:
# 	PH = Polyhedra
# 	poly = vpoly(points)
# 	PH.removevredundancy!(poly)
# 	return Vec{2}.(collect(PH.points(poly)))
# end

"""
    convex_hull_list(points)

Returns the convex hull of the points, as a list of indexes (in direct
order, starting at a reproducible index in the list of points).
"""
function convex_hull_list(points)
  # Uses Graham scan
  # In practice this is faster than using `Polyhedra.jl`.
#   println("points=$points, length=$(length(points))")
  i0 = findextrema(points;
    lt=(p,q)->(p[2]<q[2])|| (p[2]==q[2] && p[1]>q[1])).min[2]
  @inline detp2(i,j,k) = det2(points[[i,j,k]]...)
	# 1024 is an arbitrary value for detecting “aligned” points (i.e. up to
	# representation errors), which should be fast for both Float and Fixed
	# division
  @inline function are_aligned(i,j,k)
    v1 = points[j]-points[i]
    v2 = points[k]-points[j]
    d = det2(v1, v2)
    c = v1 ⋅ v2
    return abs(d) < abs(c)/1024
  end
  scan = sort(filter(!isequal(i0), eachindex(points)),
    lt=(p,q)->detp2(i0,p,q) > 0)
#   println("i0=$i0, scan=$scan")
  stack = [i0, scan[1]]
  for h in scan[2:end]
#     println("scanning: $stack + $h")
    v1 = points[stack[end]] - points[stack[end-1]]
    v2 = points[h] - points[stack[end]]
    s = det2(v1, v2)
    c = v1 ⋅ v2
    if abs(s) < abs(c)/1024 && c < 0 # points are aligned and backwards
			# here we know that we can insert at (end)
			# look for an insertion point i:
			i = length(stack)
			while i > 2
# 				println(" try to insert at $i")
				v1 = points[stack[i]] - points[stack[i-1]]
				v2 = points[h] - points[stack[i]]
				s = det2(v1, v2)
				c = v1 ⋅ v2
				if s < -1e-3*abs(c)
# 					println(" break at $i")
					break
				end
				i -= 1
			end
# 			println("  inserting at $i")
			insert!(stack, i, h)
			continue
# 			println("  now stack=$stack")
    end
    while detp2(last(stack), h, stack[end-1]) < 0
      pop!(stack)
    end
    push!(stack, h)
  end
  return stack
end

"""
    convex_hull([vector of 2d points])

Returns the convex hull (as a vector of 2d points, ordered in direct
order).
"""
@inline convex_hull(points::AbstractVector{<:Vec{2}}) =
	points[convex_hull_list(points)]


# this is the version using MiniQhull: #««
# convex_hull(points::AbstractVector{<:AnyVec(2)}) =
#		# Delaunay triangulation:
#		let T = MiniQhull.delaunay([p[i] for i in 1:2, p in points]),
#				N = length(points),
#				M = zeros(Bool, N, N) # ⚠ memory O(N²)
#		# mark all edges:
#		for (a,b,c) in eachcol(T)
#			b1 = points[b] - points[a]
#			c1 = points[c] - points[a]
#			d = b1[1]*c1[2] - b1[2]*c1[1] # determinant === orientation of triangle
#			if d < 0
#				M[a,b] = M[b,c] = M[c,a] = true
#			else
#				M[b,a] = M[c,b] = M[a,c] = true
#			end
#		end
#		# list of remaining edges (retrograde oriented)
#		L= sort([(i,j) for i in 1:N, j in 1:N if M[i,j] && ! M[j,i]], by=v->v[1])
#		next(i) = L[searchsorted(L, i, by=y->y[1])][1][2]
#		R = zeros(Int, length(L))
#		R[1:2] .= L[1] # initialize with first edge
#		for i in 3:length(R)
#			R[i] = next(R[i-1])
#		end
#		# returns in retrograde ordering (OpenSCAD convention):
#		points[R]
# end#»»
# 3d convex hull ««2

"""
    convex_hull(x::AbstractGeometry{3}...)

Returns the convex hull of the union of all the given solids, as a
pair `(points, faces)`. `faces` is a list of triangles.
"""
@inline convex_hull(x::AbstractGeometry{3}) =
	convex_hull(vcat([vertices(y) for y in x]...))

"""
    convex_hull(vector of 3d points)

Returns the convex hull of these points, as a pair `(points, faces)`.
All the faces are triangles.
"""
function convex_hull(p::AbstractVector{<:Point{3,T}}) where{T}
	M = hcat(Vector.(coordinates.(p))...)
	PH = Polyhedra
	poly = PH.polyhedron(PH.vrep(transpose(M)), polyhedra_lib(T))
	R = PH.removevredundancy!(poly)
	V = Point{3,T}.(collect(PH.points(poly)))

	triangles = Vec{3,Int}[]
	for i in PH.eachindex(PH.halfspaces(poly)) # index of halfspace
		h = PH.get(poly, i)
		pts = PH.incidentpointindices(poly, i) # vector of indices of points
		for t in triangulate_face(
				[Point(PH.get(poly, j)) for j in pts];
				direction = h.a,
				map = [j.value for j in pts],
				convex = Val(true))
			(a,b,c) = (V[j] for j in t)
			k = det([b-a c-a h.a])
			push!(triangles, (k > 0) ? t : SA[t[1], t[3], t[2]])
		end
	end
	return (points=V, faces=triangles)
end


# 2d Minkowski sum««1
# Convolution of polygons««2
# http://acg.cs.tau.ac.il/tau-members-area/general%20publications/m.sc.-theses/thesis-lienchapter.pdf
"""
    circularcmp(v1, v2, v3, [Val(:offset)])

Circular comparison predicate; returns true iff directions of vectors
`v1`, `v2`, `v3` are arranged in a trigonometric ordering along the unit
circle.

If `Val(:offset)` is passed then `v1`, `v3` are infinitesimally rotated
in the positive direction compared to `v2`.
"""
function circularcmp(v1, v2, v3)
	d1 = v2[1]*v3[2] ≥ v2[2]*v3[1]
	d2 = v3[1]*v1[2] ≥ v3[2]*v1[1]
	d3 = v1[1]*v2[2] ≥ v1[2]*v2[1]
	return (d1+d2+d3) ≥ 2
end
function circularcmp(v1, v2, v3, ::Val{:offset})
	d1 = v2[1]*v3[2] > v2[2]*v3[1]
	d2 = v3[1]*v1[2] ≥ v3[2]*v1[1]
	d3 = v1[1]*v2[2] ≥ v1[2]*v2[1]
	return (d1+d2+d3) ≥ 2
end

function convolution(p::AnyPath{2}, q::AnyPath{2})
	(np, nq) = (length(p), length(q))
	ep = [p[cyclindex(i, p)]-p[i] for i in eachindex(p)] # edges of p
	eq = [q[cyclindex(i, q)]-q[i] for i in eachindex(q)]
	j0 = 0
	newpoly = similar(p, 0)
	for ip in eachindex(p)
		for iq in eachindex(q)
			iq0 = cyclindex(iq, q, -1)
			if circularcmp(eq[iq0], ep[ip], eq[iq], Val(:offset))
				push!(newpoly, p[ip]+q[iq])
				push!(newpoly, p[cyclindex(ip, p)]+q[iq])
			end
		end
	end
	newpoly
end
p⋆q = convolution(p, q)
# Minkowski sum of polygons and their unions ««2
function minkowski(p::AnyPath{2}, q::AnyPath{2})
	r = convolution(p, q)
	return simplify([r]; fill=:nonzero)
end
function minkowski(vp::Vector{<:AnyPath{2}}, vq::Vector{<:AnyPath{2}})
	vr = vec([convolution(p, q) for p in vp, q in vq])
	return simplify(vr; fill=:nonzero)
end

# TODO: 3d Minkowski««2

# 2d subsystem««1
# PolyUnion««2
# type and constructors from points««
"""
		PolyUnion

Represents a union of polygons. Each polygon is assumed to be simple and
ordered in trigonometric ordering.
"""
struct PolyUnion{T} <: AbstractGeometry{2,T}
	poly::Vector{Path{2,T}}
	@inline PolyUnion{T}(p::AbstractVector{<:AnyPath{2,T}}) where{T} =
		new{T}(Path{2,T}.(p))
end
@inline (U::Type{PolyUnion})(p::AbstractVector{<:AnyPath{2,T}}) where{T} =
		U{real_type(eltype.(eltype.(p))...)}(p)

@inline (U::Type{<:PolyUnion})(path::AnyPath{2}...) = U([path...])

@inline vertices(u::PolyUnion) = vcat(u.poly...)

# this is used to broadcast conversion for recursive conversion to PolyUnion:
@inline _convert(U::Type{<:PolyUnion}, l, parameters) =
	[ U(s, parameters) for s in l ]

# »»
# I/O««
function scad(io::IO, u::PolyUnion{S}, spaces::AbstractString) where{S}
	print(io, spaces, "// union of $(length(u.poly)) polygon(s):\n")
	length(u.poly) != 1 && print(io, spaces, "union() {\n")
	for p in u.poly
		print(io, spaces, " polygon([")
		join(io, convert.(Vec{2,Float64}, p), ",")
		print(io, "]);\n")
	end
	length(u.poly) != 1 && print(io, spaces, "}\n")
end
#»»
# Conversion from leaf 2d types««2
@inline PolyUnion(l::AbstractGeometry{2}; kwargs...) =
	PolyUnion{real_type(eltype(l))}(l, merge(_DEFAULT_PARAMETERS, kwargs.data))

@inline (U::Type{<:PolyUnion})(x::Square, parameters) =
	U(Vec{2}.(vertices(x)))
@inline (U::Type{<:PolyUnion})(x::Circle, parameters) =
	U(Vec{2}.(vertices(x, parameters)))
@inline (U::Type{<:PolyUnion})(x::Polygon, parameters) =
# FIXME: simplify and define orientation
	U(Vec{2}.(vertices(x)))

@inline function (U::Type{<:PolyUnion})(f::AffineTransform{2}, parameters)
	child = U(f.child, parameters)
	return U([ f.data.(path) for path in child.poly ])
end
@inline (U::Type{<:PolyUnion})(s::SetParameters{2}, parameters) =
	U(s.child, merge(parameters, s.data))
# fall-back case (`color`, etc.):
@inline (U::Type{<:PolyUnion})(s::Transform{S,2}, parameters) where{S} =
	U(s.child, parameters)

function vertices(s::Square)
	# in trigonometric order:
	(u, v) = s.size
	return Point{2}.([
		SA[u[1],u[2]],
		SA[v[1],u[2]],
		SA[v[1],v[2]],
		SA[u[1],v[2]]])
end
@inline vertices(c::Circle, parameters) =
	Point{2}.(unit_n_gon(c.radius, parameters))
# Reduction of CSG operations««2
@inline (clip(op, u::U...)::U) where{U<:PolyUnion} =
	reduce((a,b)->U(clip(op, a.poly, b.poly)), u)

# Set-wise operations:
@inline (U::Type{<:PolyUnion})(s::ConstructedSolid{2,:union}, parameters) =
	clip(:union, _convert(U, s.children, parameters)...)

@inline (U::Type{<:PolyUnion})(s::ConstructedSolid{2,:intersection}, parameters) =
	clip(:intersection, _convert(U, s.children, parameters)...)

function ((U::Type{<: PolyUnion})(s::ConstructedSolid{2,:difference}, parameters)::U)
	length(s.children) == 1 && return U(s.children[1], parameters)
	L = _convert(U, s.children, parameters)
	r2= clip(:union, view(L,2:length(L))...)
	clip(:difference, L[1], r2)
end

# Convex hull:
function (U::Type{<:PolyUnion})(s::ConstructedSolid{2,:hull}, parameters)
	pts = points.(_convert(U, s.children, parameters))
	U(convex_hull([pts...;]))
end

# Minkowski sum:
function (U::Type{<:PolyUnion})(s::ConstructedSolid{2,:minkowski},
	parameters)::U
	reduce((a,b)->U(minkowski(a.poly, b.poly)),
		_convert(U, s.children, parameters))
end
# function _combine2(::Val{:minkowski}, a::PolyUnion{T}, b::PolyUnion{T}) where{T}
# 	# not implemented in Clipper.jl...
# end


# Offset ««2
"""
		offset(P::Polygon, u::Real; options...)

Offsets polygon `P` by radius `u` (negative means inside the polygon,
positive means outside). Options:

 - `join_type`: :round | :square | :miter
 - `miter_limit` (default 2.0)
"""
function offset(U::PolyUnion{T}, u::Real;
		join_type = :round,
		miter_limit::Float64 = 2.0,
		precision::Real = 0.2) where{T}

	c = ClipperOffset(miter_limit, clipper_float(clipper_type(T), precision))
	add_paths!(c, U.poly, join_type, Clipper.EndTypeClosedPolygon)
	PolyUnion(execute(T, c, u))
end
@inline offset(x::AbstractGeometry{2}, args...; kwargs...) =
	offset(PolyUnion(x), args...; kwargs...)

# Draw ««2
"""
    draw(path, width; kwargs...)

    ends=:round|:square|:butt|:closed
    join=:round|:miter|:square
"""
function draw(path::Path{2,T}, width::Real;
		ends::Symbol = :round, join::Symbol = :round,
		miter_limit::Float64 = 2.0, precision::Real = 0.2) where{T}
	CT = clipper_type(T)
	RT = clipper_rettype(T)
	c = ClipperOffset(miter_limit, clipper_float(CT, precision))
	println("join=$join, round=$round")
	Clipper.add_path!(c, clipper_path(path),
		JoinType(Val(join)), EndType(Val(ends)))
	println("$(clipper_type(T)) $(CT(1.)); prec=$(Float64(CT(precision)))")
	ret = clipper_unpath.(RT, Clipper.execute(c, clipper_float(CT, width)/2))
	return PolyUnion(ret)
end

# Convex hull««2
# """
# 		convex_hull(x::AbstractGeometry{2}...)
# 
# Returns the convex hull of the union of all the given solids, as a
# `PolyUnion` structure.
# """
@inline convex_hull(x::AbstractGeometry{2}...; params=_DEFAULT_PARAMETERS) =
	convex_hull(PolyUnion(union(x...), params))

@inline convex_hull(u::PolyUnion) = convex_hull(Vec{2}.(vertices(u)))

# Basic 3d geometry««1
# Low-level functions««2
norm²(v::Vec) = sum(v .* v)
distance²(p::Point, q::Point) = norm²(p-q)

function face_normal(points)
	@assert length(points) >= 3
	return cross(points[2]-points[1], points[3]-points[1])
end
"""
    supporting_plane(t::Triangle)

Returns an equation (`a*x = b`) of the supporting plane, with `a`
pointing *outwards*.
"""
function supporting_plane(t::Triangle)
	(p1, p2, p3) = t
	c = cross(p2-p1, p3-p1)
	b = dot(c, p1)
	return Polyhedra.HyperPlane(c, b)
end

"""
    circular_lt

Circular comparison of vectors, sorted according to their angle in
]-π,π]. Implemented with only integral arithmetic (no `atan2`, `√` or `/`).
"""
@inline function circular_lt(p,q)
	if p[2] < 0
		if q[2] ≥ 0 return true; end
	else # p[2] ≥ 0
		if q[2] < 0 return false; end
		if p[2] == 0 && q[2] == 0 return p[1] > q[1]; end
	end
	return det2(p, q) > 0
end
"""
    circular_sign(u,v)

Let `α` and `β` be the angles of `u`,`v` in ]-π, π].
This function returns a number <0 iff `α` < `β`, >0 iff `α` > `β`,
and `0` iff `α` == `β`.
"""
@inline function circular_sign(u, v)
	if u[2] < 0
		v[2] ≥ 0 && return -1
	else
		v[2] < 0 && return 1
	end
	return det2(u, v)
end



# Using a Box as a bounding box««2
struct Box{D,T} <: GeometryBasics.GeometryPrimitive{D,T}
	min::Point{D,T}
	max::Point{D,T}
end
@inline ∈(x::AbstractVector, b::Box) = all(b.min .≤ x .≤ b.max)
# @inline ∈(x::Point, b::Box) = x.coords ∈ b
@inline isempty(b::Box) = any(b.min .> b.max)
@inline intersect(a::Box, b::Box) =
	Box(Point(max.(a.min, b.min)), Point(min.(a.max, b.max)))
boundingbox(points::Point{D,T}...) where{D,T} =
	Box{D,T}(min.(points...), max.(points...))
boundingbox(g::AbstractGeometry) = boundingbox(GeometryBasics.coordinates(g)...)

# 3d -> 2d projections««2
const plus1mod3 = SA[2,3,1]
const plus2mod3 = SA[3,1,2]
@inline function project_2d(direction::AbstractVector, index::Val = Val(false))
	# we inline the 'findmax' call since we know the length is 3:
	# (doing this about halves the running time of this function. Besides,
	# since the value 'e' only takes three possible values, it enables the
	# compiler to propagate constants.)
	a1 = abs(direction[1]); a2=abs(direction[2]); a3=abs(direction[3])
	k = (a1 < a2) ? ((a2 < a3) ? 3 : 2) : ((a1 < a3) ? 3 : 1)
	v = direction[k]
	@inbounds p = (v > 0) ? SA[plus1mod3[k], plus2mod3[k]] :
		SA[plus2mod3[k], plus1mod3[k]]
	return _project_2d(index, p, k)
end
# @inline function project_2d1(direction::AnyVec{3}, index::Val = Val(false))
# 	# we inline the 'findmax' call since we know the length is 3:
# 	# (doing this about halves the running time of this function)
# 	a1 = abs(direction[1]); a2=abs(direction[2]); a3=abs(direction[3])
# 	# this part does not do any speed-up (constant propagation):
# 	if a1 < a2
# 		if a2 < a3 @goto max3; end
# 		if direction[2] > 0
# 			return _project_2d(index, SA[3,1], 2)
# 		else
# 			return _project_2d(index, SA[1,3], 2)
# 		end
# 	elseif a1 < a3
# 		@label max3
# 		if direction[3] > 0
# 			return _project_2d(index, SA[1,2], 3)
# 		else
# 			return _project_2d(index, SA[2,1], 3)
# 		end
# 	else
# 		if direction[1] > 0
# 			return _project_2d(index, SA[2,3], 1)
# 		else
# 			return _project_2d(index, SA[3,2], 1)
# 		end
# 	end
# end
@inline _project_2d(::Val{false}, p, _) = p
@inline _project_2d(::Val{true}, p, e) = (p, e)

"""
    project_2d(plane::Polyhedra.HyperPlane)

Returns a (named) tuple `(coordinates, linear, origin)` where
 - `coordinates` is the set of coordinates to keep for projection,
 - `linear`*x+`origin` is an affine section.
"""
function project_2d(plane::Polyhedra.HyperPlane)
	v = direction(plane)
  (coords, k) = project_2d(v, Val(true))
	f = inv(convert(real_type(eltype(v)), v[k]))
		# e=1: proj=(2,3) sect=[-b/a -c/a;1 0;0 1]
		# e=2: proj=(3,1) sect=[0 1;-a/b -c/b;1 0]
		# e=3: proj=(1,2) sect=[1 0;0 1;-a/c -b/c]
		# e=1: proj=(3,2) sect=[-c/a -b/a;0 1;1 0]
		# e=2: proj=(1,3) sect=[1 0;-a/b -c/b;0 1]
		# e=3: proj=(2,1) sect=[0 1;1 0;-b/c -a/c]
	m = SMatrix{3,2}((i==k) ? -f*v[coords[j]] : (i == coords[j])
			for i=1:3, j=1:2)
	c = SVector{3}((i==k) ? plane.β*f : 0 for i in 1:3)
	return (coordinates=coords, lift=Affine(m, c))
end

# Rays««2
"""
    AffineRay

An open ray, of the form `a + ]0,∞[ v`.
"""
struct AffineRay{D,T} <: AbstractGeometry{D,T}
	origin::Point{D,T}
	direction::Vec{D,T}
end

@inline direction(a::AffineRay) = a.direction
@inline origin(a::AffineRay) = a.origin
@inline AffineRay(origin::SVector{D}, direction::SVector{D}) where{D} =
	AffineRay{D,promote_type(eltype.((origin,direction))...)}(origin, direction)

"""
    intersects(a::AffineRay{3}, t::Triangle)

Returns 1 iff ray intersects triangle in given order,
-1 if it intersects in opposite order, otherwise 0.

Algorithm is inspired by Segura-Feito[1]:
after translating everything so that the ray starts at the origin,
we apply the linear transformation
x ↦ (⟨x,v2,v3⟩,⟨v1,x,v3⟩,⟨v1,v2,x⟩)  (⟨⟩ is the determinant)
This maps the three points of the triangle to
(δ,0,0), (0,δ,0), (0,0,δ), where δ=⟨v1,v2,v3⟩.
The sign of δ gives the position of the origin w.r.t the triangle: δ⟩0
iff the origin is *inside* the triangle.

Once the vertices of the triangle are aligned to the axes, the ray
intersects the triangle iff the 3 coordinates of its direction `u` are >0.
This means that ⟨u,v2,v3⟩, ⟨v2,u,v3⟩, ⟨v1,v2,u⟩ > 0.

[1] https://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.2.2084&rep=rep1&type=pdf

"""
function intersects(a::AffineRay, t::Triangle, strict = false)
	u = a.direction
	(v1, v2, v3) = [x-a.origin for x ∈ vertices(t)]
	d = det3(v1, v2, v3)
	# FIXME: could be make slightly faster (but less readable)
	# by precomputing u∧v2
	if strict
		if (d > 0 && det3(u, v2, v3) > 0
			&& det3(v1, u, v3) > 0 && det3(v1, v2, u) > 0)
			return 1
		elseif (d < 0 && det3(u, v2, v3) < 0
			&& det3(v1, u, v3) < 0 && det3(v1, v2, u) < 0)
			return -1
		end
	else
		if (d ≥ 0 && det3(u, v2, v3) ≥ 0
			&& det3(v1, u, v3) ≥ 0 && det3(v1, v2, u) ≥ 0)
			return 1
		elseif (d ≤ 0 && det3(u, v2, v3) ≤ 0
			&& det3(v1, u, v3) ≤ 0 && det3(v1, v2, u) ≤ 0)
			return -1
		end
	end
	return 0
end


struct AffineRayInv{D,T} <: AbstractGeometry{D,T}
	origin::Vec{D,T}
	direction::Vec{D,T}
	inv_dir::Vec{D,T}
end
_inv0(x::Real) = iszero(x) ? zero(real_type(x)) : inv(to_real(x))
@inline inv(a::AffineRay{D,T}) where{D,T} =
	AffineRayInv{D,real_type(T)}(a.origin, a.direction, _inv0.(a.direction))

"""
    intersects(a::AffineRay{3}, b::Box)

https://tavianator.com/2011/ray_box.html
"""
function intersects(a::AffineRayInv{3}, b::Box; strict=false)
	tmin = zero(eltype(a.direction))
	tmax = typemax(eltype(a.direction))
	for i in 1:3
		# position = x + t*z, hence t = (position-x)*z1
		x = a.origin[i]; z = a.direction[i]; z1 = a.inv_dir[i]
		u = b.proj[i]
		if iszero(z)
			if x < u.low || x > u.high return false; end
		else
			# if z > 0 then p_min = x+tmin*z, p_max = x+tmax*z
			#   (thus tmin = (pmin-x)*z1, tmax = (pmax-x)*z1)
			# else tmin, tmax are swapped
			@inline f(v) = (v-x)*z1
			if z > 0
				tmax = min(tmax, f(u.high))
				tmin = min(tmin, f(u.low))
			else
				tmax = min(tmax, f(u.low))
				tmin = min(tmin, f(u.high))
			end
			if strict
				if tmin ≥ tmax return false; end
			else
				if tmin > tmax return false; end # early abort
			end
		end
	end
	return true
end

function intersections(a::AffineRay, s::TriangulatedSurface,
		minface = 0)
	return sum(intersects(a, Triangle(s,i), i>minface )
		for i in eachindex(faces(s)))
end
# Triangulations««1
# 2d triangulation««2
"""
    triangulate_loop(path::Path{2})

Given a closed loop of points,
returns a Delaunay triangulation of the *inside* of the loop only.
(Constrained triangulation and all triangles lying outside the loop are
removed. Triangles are oriented in the same direction as the loop.)

The triangulation is returned as a vector of [i1, i2, i3] = integer indices
in the list of points.
"""
function triangulate_loop(points::Matrix{Float64})
	N = size(points, 1)
	return LibTriangle.constrained_triangulation(
		points,
		collect(1:N), # identity map on points
		[mod1(i+j-1, N) for i in 1:N, j in 1:2])
end
@inline triangulate_loop(points::AnyPath{2}) =
	triangulate_loop(Matrix{Float64}(vcat(transpose.(points)...)))
# 	N = length(points)
# 	m = Matrix{Float64}(vcat(transpose.(points)...))
# 
# 	ct = LibTriangle.constrained_triangulation(
# 		m,
# 		collect(1:N), # trivial map on points
# 		[mod1(i+j-1, N) for i in 1:N, j in 1:2])
# 	# returns triangles of the same orientation as the loop:
# 	# outer triangles are removed by Triangle library
# 	# each triangle is either inner or outer
# 	# this is determined e.g. by its barycenter
# # 	return filter(t->point_in_polygon(sum(points[t])/3, points) > 0, ct)
# 	return ct
# end

# 3d face triangulation««2
"""
    triangulate_face(points; direction, map, convex)

Returns a triangulation of the face (assumed convex; points in any order)
Optional keyword arguments:
 - `direction` is a normal vector (used for projecting to 2d).
 - `map` is a labeling of points (default is identity map).
 - `convex` is a Val(true) or Val(false).

The triangulation is returned as a vector of StaticVector{3,Int},
containing the labels of three points of each triangle.
"""
function triangulate_face(
		points::AbstractVector{<:Point{3}}
		;
		direction::AbstractVector = face_normal(points),
		map::AbstractVector{<:Integer} = [1:length(points)...],
		convex::Val = Val(false)
		)
	coords = project_2d(direction)
	N = length(points)
	# this common case deserves a shortcut:
	if N == 3 return [Vec{3}(map)]; end

	points2d = Matrix{Float64}(undef, N, 2)
	for (i, p) in pairs(points), (j, x) in pairs(coords)
		points2d[i, j] = p[x]
	end
	if convex isa Val{true}
		r= Vec{3,Int}.(LibTriangle.basic_triangulation(points2d, map))
		return r
	else
		edges = vcat(([map[i] map[mod1(i+1,N)]] for i in 1:N)...)
		r= Vec{3,Int}.(LibTriangle.constrained_triangulation(points2d,
			map, edges))
		return r
	end
end
# Triangulating surfaces««2
"""
    triangulate(s::AbstractSurface)

Converts a `AbstractSurface` to a `TriangulatedSurface`.
This triangulates all faces and removes all degenerate (collinear) faces.
"""
function triangulate(s::AbstractSurface)
	triangles = Vec{3,Int}[]
	for f in faces(s)
		# kill all 2-faces
		length(f) <= 2 && continue
		# triangulate
		thisface = triangulate_face(vertices(s)[f]; map=f)
		# kill all degenerate faces
		@inline is_degenerate(t) =
			iszero(norm(face_normal(vertices(s)[t])))
		push!(triangles, filter(!is_degenerate, thisface)...)
	end
	return TriangulatedSurface(vertices(s), triangles)
end
# 3d union and intersection««1
# After [Zhou, Grinspun, Zorin, Jacobson](https://dl.acm.org/doi/abs/10.1145/2897824.2925901)
# Self-intersection««2
# TODO: move all intersection computations to clean little functions
"""
    self_intersect(s::AbstractTriangulatedSurface)

Returns all self-intersections of `s`, as a `NamedTuple`:
 - `points`: all new points of intersection (as a vector of `Point{3}`,
   to be appended to the original geometric points of the structure).
 - `edge_points`: for all edges, a vector of indices of new points
   (sorted in the direction of the edge).
 - `face_points`: for all faces of `s`, the list of new points in this face,

Point indices are returned as indices in `vertices(s)` ∪ {new points}.

"""
function self_intersect(s::AbstractTriangulatedSurface)
	println("incidence...")
	inc = incidence(s; vf=false) # we only need edge_faces
	println("planes...")
	# we precompute all planes: we need them later for edge intersections
	planes = [ supporting_plane(tri) for tri in s ]

	n = nvertices(s)
# 	println("self_intersect: $n points at beginning")
	new_points = similar(vertices(s), 0)
	T = eltype(eltype(vertices(s)))
	face_points = [ Int[] for _ in faces(s) ]
	edge_points = Dict([ k=>Int[] for k in keys(inc.edge_faces) ])
	edge_coords = Dict([ k=>T[] for k in keys(inc.edge_faces) ])# used for sorting
	@inline function create_point!(p)
		j = findfirst(isequal(p), new_points)
		if j isa Int; return j; end
		push!(new_points, p)
		return n + length(new_points)
	end
	@inline function add_point_edge!(e, k, p)#««
# 		println("adding point $k=$p to edge $e")
# 		println("  $e=[$(vertices(s)[e])]")
# 		println("  current points for this edge: $(edge_points[e])")
# 		println("  current coordinates: $(edge_coords[e])")
		vec = vertices(s)[e[2]]-vertices(s)[e[1]]
		# fixme: unroll this loop to allow constant-propagation:
		i = argmax(abs.(vec))
		if length(edge_points[e]) == 0 # most common case
			push!(edge_points[e], k)
			push!(edge_coords[e], p[i])
			return
		end
# 		println("  sorted by coordinate $i ($(vec[i]))")
# 		println("  e=$e")
		rev = (vec[i] < 0)
		j = searchsorted(edge_coords[e], p[i]; rev=rev)
# 		println("  inserting at position $j, $(first(j))")
		insert!(edge_points[e], first(j), k)
		insert!(edge_coords[e], first(j), p[i])
# 		println("  now edge_points[$e] = $(edge_points[e])")
	end#»»

	println("faces...")
	# face-edge and face-vertex intersections««
	for (i, f) in pairs(faces(s))
# 		println("  face $i: $f")
		# set up infrastructure for this face
		triangle = vertices(s)[f]
		bbox = boundingbox(triangle...)
		plane = planes[i]
		(proj, lift) = project_2d(plane)
		triangle2 = hrep([p[proj] for p in triangle]...) # hrep of projection

		# face-vertex intersections««
		for (j, p) in pairs(vertices(s))
			if j ∈ f || p ∉ bbox || p ∉ plane
				continue
			end
			p2 = Point(p[proj])
			if any(h(p2) <= 0 for h in triangle2)
				continue
			end
			# vertex is inside this face, mark it
# 			println("vertex $j inside face $i=$f")
			push!(face_points[i], j)
		end#»»
		# face-edge intersections««
		for (e, flist) in pairs(inc.edge_faces)
			segment = Segment(vertices(s)[e]...)
			if isempty(boundingbox(segment) ∩ bbox) || !isempty(e ∩ f)
				continue
			end
			# FIXME move this to a segment ∩ triangle function
			(z1, z2) = plane.(vertices(segment))
			if z1 * z2 >= 0
				continue
			end
			# the previous line ensures that z1 ≠ z2, so this never fails:
			p2 = Point((z2*segment[1][proj] - z2*segment[2][proj])/(z2-z1))
			if any(h(p2) <= 0 for h in triangle2)
				continue
			end
			p3 = lift(p2)
			k = create_point!(p3)
# 			println("edge $e intersects face $i=$f at $k=$(last(new_points))")
# 			println("  adding point $k to face $i=$f")
			push!(face_points[i], k)
			add_point_edge!(e, k, p3)
		end#»»
	end#»»
	println("edges...")
	# edge-edge and edge-vertex intersections««
	for (e, flist) in pairs(inc.edge_faces)
		# two equations define this edge:
		# first one is that of an adjacent face
		eq1 = planes[abs(flist[1])]
		# for the second equation, it happens (quite often) that edges
		# delimitate two parallel faces, so we cannot use a second face
		# equation. Instead we project on first plane and look for an
		# equation of the projection here.
		v = direction(eq1)
		(proj, kmax) = project_2d(v, Val(true))
		eq2 = line(vertices(s)[e[1]][proj] => vertices(s)[e[2]][proj])

		bbox = boundingbox(vertices(s)[e]...)
		# edge-vertex intersections:««
		for (j, p) in pairs(vertices(s))
			if p ∉ bbox || j ∈ e || eq2(Point(p[proj]...)) ≠ 0 || eq1(p) ≠ 0
				continue
			end

			# edge (segment) is intersection of bbox and line,
			# therefore here we know that the point is on the edge:
# 			println("vertex $j is on edge $e")
			add_point_edge!(e, j, p)
		end#»»
		# edge-edge intersections:««
		for (e1, flist1) in pairs(inc.edge_faces)

			# TODO: could this be made simpler by just checking if determinant
			# is zero?
			segment = Segment(vertices(s)[e]...)
			# this makes the iteration triangular:
			if e1 == e break; end
			seg1 = Segment(vertices(s)[e1]...)
			if isempty(boundingbox(seg1) ∩ bbox) continue; end
			if !isempty(e ∩ e1) continue; end
			p = inter(segment, seg1)
			if p isa Nothing continue; end
			if p ∈ vertices(s)[[e[1], e[2], e1[1], e1[2]]]
				# this is an edge-vertex intersection
				continue;
			end
			if eq2(Point(p[proj])) ≠ 0 continue; end
			# point p is a new point and on both edges e and e1
# 			println("edges $e and $e1 intersect")
# 			println("""
# Edges $e, $e1:
# flist = $flist = $(faces(s)[abs.(flist)])
# equations = $eq1, $eq2
# segment = $segment
# (z1, z2) = $((z1, z2))
# (w1, w2) = $((w1, w2))
# candidate p (segment ∩ z): $p
# """)
# 		@assert false
			k = create_point!(p)
# 			println("edge intersection: $e, $e1 => $k = $p")
# 			println("  $(vertices(s)[e])\n  $(vertices(s)[e1])")
			add_point_edge!(e, k, p)
			add_point_edge!(e1, k, p)
		end#»»
	end#»»
	return (points = new_points,
		edge_points = edge_points,
		face_points = face_points)
end
# Sub-triangulation««2
# FIXME: after [ZGZJ], this should be done in *clusters* of coplanar
# faces, so as to ensure compatible triangulation in exceptional cases.

function remove_opposite_faces(flist)
	keep = trues(length(flist))
	for (i, f) in pairs(flist), j in 1:i-1
		g = flist[j]
		if ((g[1] == f[1] && g[2] == f[3] && g[3] == f[2])
		  ||(g[2] == f[2] && g[1] == f[3] && g[3] == f[1])
			||(g[3] == f[3] && g[1] == f[2] && g[2] == f[1]))
			keep[i] = keep[j] = false
		end
	end
	return flist[keep]
end
"""
    subtriangulate(s::AbstractTriangulatedSurface)

Returns a refined triangulation of `s` with vertices at all
self-intersection points.
"""
function subtriangulate(s::AbstractTriangulatedSurface)
	println("self-intersect...")
	self_int = self_intersect(s)
	println("subtriangulate...")
	newpoints = [ vertices(s); self_int.points ]
	newfaces = SVector{3,Int}[]
	@inline edge_points(e1, e2) =
		e1 < e2 ? self_int.edge_points[SA[e1,e2]] :
		reverse(self_int.edge_points[SA[e2,e1]])

	for (i, f) in pairs(faces(s))
		extra = self_int.face_points[i]
# 		println("subtriangulating face $f: inserting $extra")
# 		println("first face $f[1] $f[2]: $(edge_points(f[1],f[2]))")
		perimeter =
			[ f[1]; edge_points(f[1], f[2]);
			  f[2]; edge_points(f[2], f[3]);
				f[3]; edge_points(f[3], f[1]); ]
# 		println("  perimeter=$perimeter")
		if length(extra) == 0 && length(perimeter) == 3
			push!(newfaces, f)
			continue
		end

		triangle = Triangle(vertices(s)[f]...)
		plane = supporting_plane(triangle)
		proj = project_2d(direction(plane))

		plist = [ perimeter; extra] # indices of points in face
		# as a matrix for `constrained_triangulation`:
		coords = [ newpoints[p][i] for p in plist, i in proj ]
# 		println("perimeter = $perimeter")
		l = length(perimeter)
		cons = [perimeter[mod1(i+j,l)] for i in eachindex(perimeter), j in 0:1]
# 		for (i, p) in pairs(plist)
# 			println("$(coords[i,1]) $(coords[i,2]) $p")
# 		end
# 		println("($coords, $plist, $cons)")
		tri = LibTriangle.constrained_triangulation(coords, plist,
			[perimeter[mod1(i+j,l)] for i in eachindex(perimeter), j in 0:1])
# 		println("triangulation = $tri")
		push!(newfaces, tri...)
	end

	newfaces = remove_opposite_faces(newfaces)
	return surface(newpoints, newfaces)
end

# Splitting into regular components««2
"""
    edgewise_connected_components(s)

Returns a tuple `(components, label)`.
 - `components[c]` is the list of face indexes in `c`-th connected comp.
 - `label[i] = c` is the component to which faced `i` belongs.

Not used. (Working on the global structure allows us to completely
dispense from ray tracing).
"""
function edgewise_connected_components(s::TriangulatedSurface,
		conn = incidence(s))
	label = [0 for _ in eachindex(faces(s))]
	components = Vector{Int}[]
	visit = Int[]
	@inline function mark_face(i, n)
		label[i] = n; push!(components[n], i)
		push!(visit, i)
	end
	for (i, f) in pairs(faces(s))
		if !iszero(label[i]) continue; end
		push!(components, Int[]); n = length(components)
		mark_face(i, n)
		while !isempty(visit)
			i = pop!(visit)
			for j in conn.faces[i]
				if !iszero(label[j]) continue; end
				mark_face(j, n)
			end
		end
	end
	return (components=components, label=label)
end
struct FaceEdgesIterator{T}
	vertices::T
end
function iterate(itr::FaceEdgesIterator, s::Int = 1)
	s > length(itr.vertices) && return nothing
	(e1, e2) = itr.vertices[[s, mod1(s+1, length(itr.vertices))]]
	return (e1 < e2 ? SA[e1, e2] : SA[e2, e1], s+1)
end
@inline length(itr::FaceEdgesIterator) = length(itr.vertices)
"""
    face_edges(f)

Returns a list of edges bordering this face, in standard form.
"""
@inline face_edges(f) = FaceEdgesIterator(f)
"""
    regular_components(s)

Returns a named tuple `(components, label, adjacency)` describing the partition of the surface in manifold patches.

 - `components`: vector of faces in this regular component.
 - `label`: label assignment (as an index in `components`) for each face.
 - `adjacency`: for each pair of adjacent components, one of the adjacent edges.
"""
function regular_components(s::TriangulatedSurface,
		conn = incidence(s))
	label = [0 for _ in eachindex(faces(s))]
	components = Vector{Int}[]
	visit = Int[]
	adjacency = zeros(SVector{2,Int},0,0)
	@inline function mark_face(i, n)
# 		println("   (marking face $i=$(faces(s)[i]) as $n)")
		label[i] = n; push!(components[n], i)
		push!(visit, i)
	end
	for (i₀, f₀) in pairs(faces(s))
		if !iszero(label[i₀]) continue; end
		push!(components, Int[]); n = length(components)
		adjacency = let new_adjacency = similar(adjacency, n, n)
			new_adjacency[1:n-1,1:n-1] .= adjacency
			fill!(view(new_adjacency, n, :), SA[0,0])
			fill!(view(new_adjacency, 1:n-1, n), SA[0,0])
			new_adjacency
		end
		mark_face(i₀, n)
		while !isempty(visit)
			i = pop!(visit); f = faces(s)[i]
# 			println(collect(face_edges(f)))
			for e in face_edges(f)
# 				println("  adjacent edge $e")
				adj = filter(!isequal(i), abs.(conn.edge_faces[e]))
# 				println("  faces = $adj")
				if length(adj) == 1
					# regular edge: 2 adjacent faces. One is f, mark the other.
					iszero(label[adj[1]]) && mark_face(adj[1], n)
				else # singular edge
				# populate adjacency matrix
					for g in adj
						l = label[g]
						iszero(l) || (adjacency[l,n] = adjacency[n,l] = e)
					end
				end
			end
		end
	end
	return (components=components, label=label, adjacency=adjacency)
end

# Arranging into cells««2
"""
    faces_around_edge(s, edge, incidence)

Returns a cyclically ordered list of all faces of `s` around edge `e`,
with sign indicating the orientation of the face. (The list starts at an arbitrary index).
"""
function faces_around_edge(s::AbstractTriangulatedSurface,
	edge, conn = incidence(s))
	# we project the faces on the plane perpendicular to edge e;
	# the eye is at position e[2] looking towards e[1].
	dir3 = vertices(s)[edge[2]]-vertices(s)[edge[1]]
	(proj, k) = project_2d(dir3, Val(true))
	dir2 = dir3[proj]
	dir2scaled = dir2/norm2(dir3)
	flist = conn.edge_faces[edge]
	# for each adjacent face, compute a (3d) vector which, together with
	# the edge, generates the face (and pointing from the edge to the face):
	# 2d projection of face_vec3 (preserving orientation)
	face_vec2 = begin
		face_pt3 = [sum(faces(s)[abs(f)]) - sum(edge) for f in flist]
		face_vec3 = [ vertices(s)[p] - vertices(s)[edge[2]] for p in face_pt3 ]
		[ v[proj] - (v ⋅ dir3)*dir2scaled for v in face_vec3 ]
	end
	reorder = sort(eachindex(flist);
		lt=(i, j) -> let b = circular_sign(face_vec2[i], face_vec2[j])
			if !iszero(b) return (b > 0)
			# the use of **signed** face numbers guarantees consistent ordering
			# even if two faces are adjacent on two edges with reversed
			# orientations
			else return flist[i] < flist[j]
			end end)

# 	println("\e[1medge $edge:\e[m proj=$proj")
# 	for i in eachindex(flist)
# 		f = abs(flist[i])
# 		println("  face $(flist[i]) = $(faces(s)[f]), vec=$(face_vec2[i])")
# # 		println("    vec2=$(face_vec2[i])  vec3=$(face_vec3[i])")
# 	end
# 	for (i, f) in pairs(flist[reorder])
# 		println("  $i: face $f = $(faces(s)[abs(f)])")
# 	end
	return flist[reorder]
end

# Computing multiplicities««2
"""
    cell_multiplicities(cells, boundary)

Given the incidence graph between cells and regular components,
compute the multiplicity of each cell.
"""
function cell_multiplicities(cells, boundary)
	multiplicity = [ typemin(0) for _ in boundary ]
	multiplicity[1] = 0; visit = [1]
	min_mul = max_mul = multiplicity[1]
	while !isempty(visit)
		i = pop!(visit)
		for c in boundary[i] # boundary components
# 			println(" from cell $i visiting component $c")
			if c > 0 # outgoing from i
				j = cells[c,2]
				if multiplicity[j] == typemin(0)
					multiplicity[j] = multiplicity[i] - 1
					(multiplicity[j] < min_mul) && (min_mul = multiplicity[j])
					push!(visit, j)
				end
			else
				j = cells[-c,1]
				if multiplicity[j] == typemin(0)
					multiplicity[j] = multiplicity[i] + 1
					(multiplicity[j] > max_mul) && (max_mul = multiplicity[j])
					push!(visit, j)
				end
			end
		end
	end
	return (multiplicity .- min_mul, max_mul .- min_mul)
end

"""
    multiplicity_levels(s)

Given a triangulated surface `s`,
returns the set of level surfaces enclosing each multiplicity component
of `s`.
"""
function multiplicity_levels(s::AbstractTriangulatedSurface)
	conn = incidence(s)
	reg = regular_components(s, conn)
	# The two next variables encode the bipartite graph of cells and
	# regular components:
	#  - `cells`: for each regular component, the pair (cell above, cell below)
	#  - `boundary`: for each cell, a list of regular components located
	#  either above or below this cell
	#  (this information is encoded in the sign of the component).
	cells = zeros(Int, length(reg.components), 2)
	boundary = Set{Int}[]
	# if face f has no cell attached: attach it (and return c)
	# otherwise: merges cell c with already-attached cell (return its id)
	@inline function attach_cell_face(c, f)
		comp = reg.label[abs(f)] # ID of regular component
		u = f > 0 ? 1 : 2
# 		println("attaching cell $c to face $f=$(faces(s)[abs(f)]), component $comp")
# 		println("  there exists currently $(length(boundary)) cells")
# 		println("  current boundary of component: $(cells[comp,:])")
		if iszero(cells[comp,u]) || cells[comp,u] == c
			cells[comp,u] = c
		else
			(c, n) = minmax(c, cells[comp,u])
# 			println("    merging cell $n =$(boundary[n]) into cell $c = $(boundary[c])")
			boundary[c] = union(boundary[c], boundary[n])
			replace!(cells, n => c)
			deleteat!(boundary, n)
		end
		@assert cells[comp,1] != cells[comp,2]
# 		println("    now cells[$comp] = $(cells[comp,:])")
# 		println("    attaching component $(sign(f)*comp) to cell $c")
# 		println("before: $(boundary[1])")
		push!(boundary[c], sign(f) * comp)
# 		c == 1 && print("\e[31;1m")
# 		println("    boundary[$c] = $(boundary[c])")
# 		c==1 && print("\e[m")
# 		println("\e[36m# $(boundary[1])\e[m")
		return c
	end
	for (i1, r1) in pairs(reg.components)
# 		println("** component ($i1, $r1)")
		for i2 in 1:i1-1
		edge = reg.adjacency[i1,i2]
# 		println("\e[1;4medge = $edge\e[m")
		iszero(edge) && continue
		r2 = reg.components[i2]
# 		println("regular components $i1=$r1 and $i2=$r2 meet at edge $edge")
		flist = faces_around_edge(s, edge, conn)
# 		println("   ordered faces at this edge: $flist, vertices=$([sum(faces(s)[abs.(f)])-sum(edge) for f in flist])")
		for (j, f) in pairs(flist)
			j1 = mod1(j+1, length(flist)); f1 = flist[j1]
			# create cell between faces f and f1
			push!(boundary, Set{Int}()); c = length(boundary)
			c = attach_cell_face(c, -f)
			c = attach_cell_face(c, f1)
# 			println("\e[32m$(cells[1,:])\e[m")
		end
		end
# 		i1 >= 3 && return (cells=cells, boundary=boundary)
	end

	(multiplicity, max_mul) = cell_multiplicities(cells, boundary)

	# cell_idx[i] = indices of cells forming region i
	cell_idx = [ filter(i->multiplicity[i] == m, eachindex(boundary))
		for m in 0:max_mul ]
	# comp_idx[i] = indices of (oriented) regular components bounding
	# region i
	comp_idx = [ collect(union(boundary[x]...)) for x in cell_idx]
	# face_idx[i] = indices of (oriented) faces bounding region i
	face_idx = [ union([ c > 0 ? reg.components[c] : .-reg.components[-c]
		for c in comp ]...) for comp in comp_idx ]
	global G = (
		components = reg.components,
		cells = cells,
		boundary = boundary,
		multiplicity = multiplicity,
		comp_idx = comp_idx,
		face_idx = face_idx,
	)

	return face_idx
end
# Binary union and intersection««2
function extract_components(fn, face_idx)
	kept = [ fn(m-1) for m in eachindex(face_idx) ]
	regc = Int[]
	for m in 1:length(kept)-1
		if kept[m] && !kept[m+1]
			# e.g. xor: 1 kept, 2 not kept
			# we add *inverted* components of m
			push!(regc, filter(x->x < 0, face_idx[m])...)
		elseif !kept[m] && kept[m+1]
			# e.g. union: 1 not kept, 2 kept
			# we add *direct* components of multiplicity m+1
			push!(regc, filter(x->x > 0, face_idx[m+1])...)
		end
	end
	return regc
	# faces outer-bounding
	# cells[i] = [cell inside patch i, cell outside patch i]
end

function select_multiplicity(fn, s::AbstractTriangulatedSurface...)
	t = subtriangulate(merge(s...))
	face_idx = multiplicity_levels(t)
	newfaces = extract_components(fn, face_idx)
	return select_faces(newfaces, t)
end

# Extrusion ««1
# Path extrusion ««2
# triangulate_between: triangulate between two parallel paths««
"""
		triangulate_between(poly1, poly2, start1, start2)

Given two polygons `poly1` and `poly2`, both of them represented as a
vector of paths, and produced as offsets from a common path,
find a triangulation for the region between the two polygons.

This functions returns a pair `(triangulation, edge)`, where:

 - the triangulation is a vector of `SVector{3,Int}`,
where each point is represented by its index. Indices in `poly1` start at
value `start1`, and in `poly2` at `start2`.

 - the edge is a pair `(lastidx1, lastidx2)` corresponding to the last
	 points visited on each polygon. (this will be useful for closing the
	 extrusion).

"""
function triangulate_between(
		poly1::AbstractVector{<:Path{D,T}},
		poly2::AbstractVector{<:Path{D,T}},
		start1::Int = 1, start2::Int = 1) where {D,T}
	Big = typemax(T)
	Triangle = SVector{3,Int}
	triangles = Triangle[]
	# head is the marker of current leading edge
	# headpoint[i] is the point marked to by head[i]
	# headidx is the new index for this marked point
	# status[i][j] is the number of last used point in j-th path of i-th poly
	head = [(1,1), (1,1)]
	headpoint = [poly1[1][1], poly2[1][1]]
	headidx = [start1, start2]
	status = zeros.(Int,length.((poly1, poly2)))
	# so far we used exactly one point on each side:
	status[1][1] = status[2][1] = 1

	# we need a way to convert (poly, path, index) to integer index««
	function first_indices(start::Int, l::Vector{Int})::Vector{Int}
		f = zeros.(Int, length(l))
		f[1] = start
		for i in 1:length(l)-1
			@inbounds f[i+1] = f[i] + l[i]
		end
		f
	end
	# firstindex[poly][path] is the first index for this path
	# firstindex[1][1] = start1
	# firstindex[1][2] = start1 + len(poly1[1]) etc.
	firstindex = (first_indices(start1, length.(poly1)),
								first_indices(start2, length.(poly2)))
	newindex(poly::Int, path::Int, index::Int)::Int =
		firstindex[poly][path] + index - 1
#»»
	# computing diagonal distances to find the smallest one:««
	distance(pt, path, i) =
		i > length(path) ? Big : distance²(pt, path[i])

	closest(pt, poly, status) =
		findmin([distance(pt, poly[i], status[i]+1) for i in eachindex(poly)])
#»»

	while true
		d1, i1 = closest(headpoint[2], poly1, status[1])
		d2, i2 = closest(headpoint[1], poly2, status[2])
		# if no more points are left, we return:
		(d1 == d2 == Big) && break

		if d1 < d2 # we append a point from poly1
			# add the triangle: head1, head2, newpoint
			s = status[1][i1] += 1
			newidx = newindex(1, i1, s)
			push!(triangles, SA[headidx[1], headidx[2], newidx])
			# update head1 to point to new point
			headidx[1] = newidx
			head[1] = (i1, s)
			headpoint[1] = poly1[i1][s]
		else
			# add the triangle: head1, head2, newpoint
			s = status[2][i2] += 1
			newidx = newindex(2, i2, s)
			push!(triangles, SA[headidx[1], headidx[2], newidx])
			# update head1 to point to new point
			headidx[2] = newidx
			head[2] = (i2, s)
			headpoint[2] = poly2[i2][s]
		end
	end
	(triangles, (headidx[1], headidx[2]))
end#»»
# path_extrude««
"""
		path_extrude(path, poly, options...)

Extrudes the given polygon (a path of points forming a simple loop)
along the given path. Both arguments are provided as a
`Vector{SVector{2}}`.

Returns a `Surface` (defined by points and a triangulation).
"""
function path_extrude(path::AbstractVector{Point{2,T}},
	poly::AbstractVector{<:Point{2}};
	join = :round,
	miter_limit::Float64 = 2.0,
	precision::Float64 = 0.25,
	closed::Bool = true
	) where{T}

	N = length(poly)
	# offset_path is a vector of vector of paths
	offset_path = offset([path], [pt[1] for pt in poly],
		join = join, ends = closed ? :closed : :butt)
	# new_points is a flat list of all 3d points produced
	new_points = [[
		[ Point(pt[1], pt[2], poly[i][2]) for pt in [p...;] ]
		for (i, p) in pairs(offset_path)
	]...;]
# 	println("returning new_points:")

	# first index for each path
	first_face = cumsum([1; # initial
		map(p->sum(length.(p)), offset_path)])
# 	println("first_face=$first_face")

	triangles = map(1:N) do i
		i1 = mod1(i+1, N)
		triangulate_between(offset_path[i], offset_path[i1],
			first_face[i], first_face[i1])
		# XXX keep the last edge for closing the poly
	end
	# this completes the set of triangles for the tube:
	tube_triangles = vcat([ t[1] for t in triangles ]...)
	last_face = [ t[2][1] for t in triangles ]
# 	println("last_face=$last_face")
	# here we decide if it is closed or open
	# if open, triangulate the two facets
	# if closed, join them together
	if closed
		more_triangles = vcat(map(1:N) do i
			j = (i%N)+1
			[ SA[first_face[i], last_face[i], first_face[j]],
				SA[first_face[j], last_face[i], last_face[j]] ]
		end...)
# 		println("more_triangles=$more_triangles")
		tube_triangles = [ tube_triangles; more_triangles ]
	else
	# TODO: triangulate the surface
	# or, for now, close with two non-triangular facets...
		more_triangles = [ reverse(first_face), last_face ]
# 		println("more_triangles=$more_triangles")
	end
	return Surface(new_points, tube_triangles)
end#»»

# Converting 3d objects to Surfaces««1
# Primitive objects««2
function vertices(s::Cube, parameters::NamedTuple)
	(u,v) = (s.min, s.max)
	return Point{3}.([
		SA[u[1],u[2],u[3]],
		SA[u[1],u[2],v[3]],
		SA[u[1],v[2],u[3]],
		SA[u[1],v[2],v[3]],
		SA[v[1],u[2],u[3]],
		SA[v[1],u[2],v[3]],
		SA[v[1],v[2],u[3]],
		SA[v[1],v[2],v[3]],
	])
# 	if s.center
# 		(a,b,c) = one_half(s.size)
# 		return [SA[-a,-b,-c], SA[-a,b,-c], SA[a,b,-c], SA[a,-b,-c],
# 			SA[-a,-b,c], SA[-a,b,c], SA[a,b,c], SA[a,-b,c]]
# 	else
# 		return [SA[0,0,0], SA[0,s.size[2],0],
# 			SA[s.size[1],s.size[2],0], SA[s.size[1],0,0],
# 			SA[0,0,s.size[3]], SA[0,s.size[2],s.size[3]],
# 			s.size, SA[s.size[1],0,s.size[3]]]
# 	end
end
function vertices(c::Cylinder, parameters)
	p1 = unit_n_gon(c.r1, parameters)
	p2 = unit_n_gon(c.r2, parameters)
	h = one_half(c.h)
	z = h*~c.center
	return vcat([ [ p; h-z ] for p in p1], [[p; h+z ] for p in p2 ])
end
@inline vertices(s::Sphere, parameters) =
	Point.(fibonacci_sphere_points(s.radius, parameters))

# All of these are convex, so we use the lazy approach and just take
# convex hull of all the points.
function Surface(s::Union{Cube, Cylinder, Sphere},
		parameters = _DEFAULT_PARAMETERS)
	p = vertices(s, parameters)
	(pts, faces) = convex_hull(p)
	return triangulate(Surface(pts, faces))
end
# Transformations««2
function (S::Type{<:AbstractSurface})(s::AffineTransform, parameters...)
	g = S(s.child, parameters...)
	b = sign(s.data)
	@assert b ≠ 0 "Only invertible linear transforms are supported (for now)"
	if b > 0
		return (typeof(g))(s.data.(vertices(g)), faces(g))
	else
		return (typeof(g))(s.data.(vertices(g)), reverse.(faces(g)))
	end
end
@inline (S::Type{<:AbstractSurface})(s::SetParameters, parameters...) =
	S(s.child, merge(parameters, s.data)...)
# Generic case (e.g. `color`): do nothing
@inline (S::Type{<:AbstractSurface})(s::Transform, parameters...) =
	S(s.child, parameters...)
# CSG operations««2
function surface(s::CSGUnion{3}, parameters...)
	return select_multiplicity(isequal(1),
		[surface(x, parameters...) for x in children(s)]...)
end
function (S::Type{<:AbstractSurface})(s::CSGInter{3}, parameters...)
	return select_multiplicity(isequal(length(children(s))),
		[S(x, parameters...) for x in children(s)]...)
end
function (S::Type{<:AbstractSurface})(s::CSGComplement{3}, parameters...)
	t = S(s.children[1], parameters...)
	return (typeof(t))(vertices(t), reverse.(faces(t)))
end
function (S::Type{<:AbstractSurface})(s::CSGDiff{3}, parameters...)
	return S(intersect(s.children[1], complement(s.children[2])),
		parameters...)
end
function (S::Type{<:AbstractSurface})(s::CSGHull{3}, parameters...)
	l = [S(x, parameters...) for x in children(s)]
	(pts, faces) = convex_hull(vcat(vertices.(l)...))
	return S(pts, faces, 0)
end
# # # Annotations ««1
# # abstract type AbstractAnnotation{D} end
# # 
# # struct DimensionArrow{D,T} <: AbstractAnnotation{D}
# # 	center::Vec{D,T}
# # 	vec::Vec{D,T}
# # 	label::AbstractString
# # 	fontsize::Float64
# # 	offset::Float64
# # end
# # """
# #     DiameterArrow{X}
# # 
# # Indicates that a diameter arrow should be drawn for the given object. The
# # parameter `X` is a type indicating which type of arrow should be drawn.
# # 
# #  - `Circle`: parametrized by center (`Vec{2}`) and radius (scalar),
# #  and possibly preferred orientation (vector if non-zero).
# # 
# #  - `Sphere`: parametrized by center (`Vec{3}`) and radius (scalar),
# #   and possibly preferred orientation.
# # 
# #  - `Cylinder`: shows a circle in 3d space, parametrized by center (`Vec{3}`), normal vector (non-zero), radius (scalar), and preferred orientation (vector; should be in the circle plane).
# # """
# # struct DiameterArrow{X<:AbstractGeometry,T,D,N} <: AbstractAnnotation{D}
# # 	center::Vec{D,T}
# # 	radius::T
# # 	orientation::Vec{D,T}
# # 	normal::N
# # 	# inner constructors enforce the correct type for N
# # 	DiameterArrow{Circle,T}(center, radius, orientation) where{T} =
# # 		new{Circle, T, 2, Nothing}(center, radius, orientation, nothing)
# # 	DiameterArrow{Sphere,T}(center, radius, orientation) where{T} =
# # 		new{Sphere, T, 3, Nothing}(center, radius, orientation, nothing)
# # 	DiameterArrow{Cylinder,T}(center, radius, orientation, normal) where{T} =
# # 		new{Cylinder, T, 3, Vec{3,T}}(center, radius, orientation, normal)
# # end
# # 
# # struct Annotate{D,T} <: AbstractGeometry{D,T}
# # 	annotations::Vector{<:AbstractAnnotation{D}}
# # 	child::AbstractGeometry{D,T}
# # end
# # # the offset is just a hint; we let the visualizer take care of using
# # # this
# # 
# #
# # Exports ««1
# export dim
# export Square, Circle, Cube, Cylinder, Polygon
# export PolyUnion
# export difference
# export ⋃, ⋂
# export offset, hull, minkowski, convex_hull
# 
# »»1
function explain(s::AbstractSurface, io::IO = stdout; scale=1,
		offset=[0.,0.,0.])
	println(io, "translate($offset) {")
	for (i, p) in pairs(Solids.vertices(s))
		println(io, """
translate($scale*$(Vector{Float64}(p)) {
	color("red") sphere(1);
	color("black", .8) linear_extrude(1) text(\"$i\", size=5);
}""")
	end
	println(io, "color(\"gray\", .7) polyhedron([")
	b = false
	for p in Solids.vertices(s)
		print(io, b ? "," : ""); b = true
		print(io, " $scale*",Vector{Float64}(coordinates(p)))
	end
	println(io, "],[")
	b = false
	for f in Solids.faces(s)
		print(io, b ? "," : ""); b = true
		println(io, " ", Vector{Int}(f) .- 1, " //", Vector{Int}(f))
	end
	println(io, "]); }")
end
@inline explain(s::AbstractSurface, f::AbstractString; kwargs...) = begin
	println("writing a surface with $(nvertices(s)) points to $f")
	open(f, "w") do io explain(s, io; kwargs...) end
end
end #««1 module
# »»1

# macro use(m)#««
# 	N = filter(x->x != m, names(eval(m)))
# 	Expr(:block, :(using .$m),
# 		map(N) do x quote
# 			$(esc(x))(args...) = eval($(esc(m))).$x(args...)
# 		end
# 	end...)
# end#»»
using StaticArrays, LinearAlgebra, FixedPointNumbers
F = Fixed{Int64, 16}


nothing
# vim: fdm=marker fmr=««,»» noet:
