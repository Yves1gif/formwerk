// FWKernel.cpp: the only place where Formwerk talks to Open CASCADE.

#include "FWKernel.h"

#include <cstring>
#include <sstream>
#include <vector>
#include <algorithm>
#include <cmath>

#include <Standard_Failure.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Wire.hxx>
#include <TopoDS_Compound.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <BRepTools.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <BRepLProp_SLProps.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <ShapeAnalysis_FreeBounds.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeFix_Shape.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <Poly_Triangulation.hxx>
#include <TopLoc_Location.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <Geom_Circle.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <gp_Pln.hxx>
#include <gp_Ax3.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Trsf.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <Interface_Static.hxx>
#include <IFSelect_ReturnStatus.hxx>

struct FWShape {
  TopoDS_Shape shape;
  // Index maps are built once per shape (shapes never change after creation).
  mutable TopTools_IndexedMapOfShape faceMap, edgeMap, solidMap;
  mutable TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
  mutable bool mapped = false;
  explicit FWShape(const TopoDS_Shape &s) : shape(s) {}
  void ensureMaps() const {
    if (mapped) return;
    TopExp::MapShapes(shape, TopAbs_FACE, faceMap);
    TopExp::MapShapes(shape, TopAbs_EDGE, edgeMap);
    TopExp::MapShapes(shape, TopAbs_SOLID, solidMap);
    TopExp::MapShapesAndUniqueAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    mapped = true;
  }
  const TopTools_IndexedMapOfShape &faces() const { ensureMaps(); return faceMap; }
  const TopTools_IndexedMapOfShape &edges() const { ensureMaps(); return edgeMap; }
  const TopTools_IndexedMapOfShape &solids() const { ensureMaps(); return solidMap; }
  const TopTools_IndexedDataMapOfShapeListOfShape &ancestors() const { ensureMaps(); return edgeFaces; }
};

struct FWMesh {
  std::vector<float> positions, normals;
  std::vector<uint32_t> indices;
  std::vector<int32_t> vertexFaces;
  std::vector<float> edgePoints;
  std::vector<int32_t> edgeSizes, edgeIds;
};

// MARK: - Helpers

static void setError(FWError *err, const char *msg) {
  if (!err) return;
  std::strncpy(err->message, msg ? msg : "unknown error", sizeof(err->message) - 1);
  err->message[sizeof(err->message) - 1] = 0;
}

static FWShape *wrap(const TopoDS_Shape &s) {
  if (s.IsNull()) return nullptr;
  return new FWShape(s);
}

static gp_Pnt P(FWVec3 v) { return gp_Pnt(v.x, v.y, v.z); }
static gp_Vec V(FWVec3 v) { return gp_Vec(v.x, v.y, v.z); }
static gp_Dir D(FWVec3 v) { return gp_Dir(v.x, v.y, v.z); }
static FWVec3 F(const gp_XYZ &p) { return FWVec3{p.X(), p.Y(), p.Z()}; }
static FWVec3 F(const gp_Pnt &p) { return F(p.XYZ()); }
static FWVec3 F(const gp_Dir &d) { return F(d.XYZ()); }

static gp_Ax3 axes(FWPlane pl) { return gp_Ax3(P(pl.origin), D(pl.normal), D(pl.xDir)); }

static gp_Pnt onPlane(const gp_Ax3 &ax, FWVec2 p) {
  gp_XYZ o = ax.Location().XYZ();
  gp_XYZ x = ax.XDirection().XYZ();
  gp_XYZ y = ax.YDirection().XYZ();
  return gp_Pnt(o + x * p.x + y * p.y);
}

// Merges coplanar faces and collinear edges that booleans leave behind,
// so the model keeps clean faces the user can pick.
static TopoDS_Shape clean(const TopoDS_Shape &s) {
  try {
    ShapeUpgrade_UnifySameDomain unify(s, true, true, false);
    unify.Build();
    TopoDS_Shape r = unify.Shape();
    return r.IsNull() ? s : r;
  } catch (...) {
    return s;
  }
}

static TopTools_IndexedMapOfShape mapOf(const TopoDS_Shape &s, TopAbs_ShapeEnum kind) {
  TopTools_IndexedMapOfShape m;
  TopExp::MapShapes(s, kind, m);
  return m;
}

/// Fuses all solids of a compound into one when they touch, so a multi-region extrude is one body.
static TopoDS_Shape fuseSolids(const TopoDS_Shape &s) {
  TopTools_IndexedMapOfShape solids = mapOf(s, TopAbs_SOLID);
  if (solids.Extent() < 2) return s;
  TopTools_ListOfShape args, tools;
  args.Append(solids(1));
  for (int i = 2; i <= solids.Extent(); i++) tools.Append(solids(i));
  BRepAlgoAPI_Fuse fuse;
  fuse.SetArguments(args);
  fuse.SetTools(tools);
  fuse.Build();
  if (!fuse.IsDone() || fuse.HasErrors()) return s;
  return clean(fuse.Shape());
}

#define FW_TRY try {
#define FW_CATCH(fallback)                                       \
  } catch (const Standard_Failure &e) {                          \
    setError(err, e.GetMessageString());                         \
    return fallback;                                             \
  } catch (const std::exception &e) {                            \
    setError(err, e.what());                                     \
    return fallback;                                             \
  } catch (...) {                                                \
    setError(err, "geometry error");                             \
    return fallback;                                             \
  }

// MARK: - Lifetime

void fw_shape_free(FWShape *s) { delete s; }
FWShape *fw_shape_copy(const FWShape *s) { return s ? new FWShape(s->shape) : nullptr; }
bool fw_shape_is_null(const FWShape *s) { return !s || s->shape.IsNull(); }

// MARK: - Building

static TopoDS_Edge makeEdge(const gp_Ax3 &ax, const FWSegment &seg) {
  switch (seg.kind) {
    case FWSegArc: {
      GC_MakeArcOfCircle arc(onPlane(ax, seg.a), onPlane(ax, seg.b), onPlane(ax, seg.c));
      if (!arc.IsDone()) Standard_Failure::Raise("invalid arc");
      return BRepBuilderAPI_MakeEdge(arc.Value()).Edge();
    }
    case FWSegCircle: {
      gp_Ax2 a2(onPlane(ax, seg.a), ax.Direction(), ax.XDirection());
      return BRepBuilderAPI_MakeEdge(gp_Circ(a2, seg.b.x)).Edge();
    }
    default: {
      gp_Pnt p1 = onPlane(ax, seg.a), p2 = onPlane(ax, seg.b);
      if (p1.Distance(p2) < 1e-7) Standard_Failure::Raise("zero-length line");
      return BRepBuilderAPI_MakeEdge(p1, p2).Edge();
    }
  }
}

FWShape *fw_make_face(FWPlane plane, const FWSegment *segments, const int32_t *loopSizes,
                      int32_t loopCount, FWError *err) {
  FW_TRY
  if (loopCount < 1) { setError(err, "no loops"); return nullptr; }
  gp_Ax3 ax = axes(plane);
  std::vector<TopoDS_Wire> wires;
  int offset = 0;
  for (int l = 0; l < loopCount; l++) {
    BRepBuilderAPI_MakeWire mw;
    for (int i = 0; i < loopSizes[l]; i++) mw.Add(makeEdge(ax, segments[offset + i]));
    offset += loopSizes[l];
    if (!mw.IsDone()) { setError(err, "loop is not closed"); return nullptr; }
    wires.push_back(mw.Wire());
  }
  BRepBuilderAPI_MakeFace mf(gp_Pln(ax), wires[0], true);
  if (!mf.IsDone()) { setError(err, "could not make face"); return nullptr; }
  for (size_t i = 1; i < wires.size(); i++) mf.Add(TopoDS::Wire(wires[i].Reversed()));
  ShapeFix_Face fix(mf.Face());
  fix.FixOrientation();
  fix.Perform();
  return wrap(fix.Face());
  FW_CATCH(nullptr)
}

FWShape *fw_make_box(FWVec3 corner, FWVec3 size, FWError *err) {
  FW_TRY
  return wrap(BRepPrimAPI_MakeBox(P(corner), size.x, size.y, size.z).Shape());
  FW_CATCH(nullptr)
}

FWShape *fw_make_cylinder(FWVec3 base, FWVec3 axis, double radius, double height, FWError *err) {
  FW_TRY
  return wrap(BRepPrimAPI_MakeCylinder(gp_Ax2(P(base), D(axis)), radius, height).Shape());
  FW_CATCH(nullptr)
}

FWShape *fw_make_compound(const FWShape *const *shapes, int32_t count) {
  BRep_Builder b;
  TopoDS_Compound c;
  b.MakeCompound(c);
  for (int i = 0; i < count; i++)
    if (shapes[i] && !shapes[i]->shape.IsNull()) b.Add(c, shapes[i]->shape);
  return new FWShape(c);
}

// MARK: - Features

FWShape *fw_extrude(const FWShape *profile, FWVec3 direction, double distance, bool symmetric,
                    FWError *err) {
  FW_TRY
  if (std::fabs(distance) < 1e-6) { setError(err, "distance is zero"); return nullptr; }
  gp_Vec dir = V(direction).Normalized();
  TopoDS_Shape base = profile->shape;
  if (symmetric) {
    gp_Trsf t;
    t.SetTranslation(dir * (-distance / 2));
    base = BRepBuilderAPI_Transform(base, t, true).Shape();
  }
  BRepPrimAPI_MakePrism prism(base, dir * distance);
  if (!prism.IsDone()) { setError(err, "extrude failed"); return nullptr; }
  return wrap(fuseSolids(prism.Shape()));
  FW_CATCH(nullptr)
}

FWShape *fw_revolve(const FWShape *profile, FWVec3 axisOrigin, FWVec3 axisDir, double angle,
                    FWError *err) {
  FW_TRY
  BRepPrimAPI_MakeRevol rev(profile->shape, gp_Ax1(P(axisOrigin), D(axisDir)), angle);
  if (!rev.IsDone()) { setError(err, "revolve failed"); return nullptr; }
  return wrap(fuseSolids(rev.Shape()));
  FW_CATCH(nullptr)
}

FWShape *fw_boolean(const FWShape *a, const FWShape *b, int32_t op, FWError *err) {
  FW_TRY
  TopoDS_Shape r;
  bool ok = false;
  if (op == FWBoolUnion) {
    BRepAlgoAPI_Fuse f(a->shape, b->shape);
    ok = f.IsDone() && !f.HasErrors(); if (ok) r = f.Shape();
  } else if (op == FWBoolCut) {
    BRepAlgoAPI_Cut c(a->shape, b->shape);
    ok = c.IsDone() && !c.HasErrors(); if (ok) r = c.Shape();
  } else {
    BRepAlgoAPI_Common c(a->shape, b->shape);
    ok = c.IsDone() && !c.HasErrors(); if (ok) r = c.Shape();
  }
  if (!ok || r.IsNull()) { setError(err, "boolean failed"); return nullptr; }
  return wrap(clean(r));
  FW_CATCH(nullptr)
}

FWShape *fw_fillet(const FWShape *s, const int32_t *edges, int32_t count, double radius,
                   FWError *err) {
  FW_TRY
  const TopTools_IndexedMapOfShape &map = s->edges();
  BRepFilletAPI_MakeFillet mk(s->shape);
  for (int i = 0; i < count; i++)
    if (edges[i] >= 1 && edges[i] <= map.Extent()) mk.Add(radius, TopoDS::Edge(map(edges[i])));
  mk.Build();
  if (!mk.IsDone()) { setError(err, "fillet too large for this edge"); return nullptr; }
  return wrap(mk.Shape());
  FW_CATCH(nullptr)
}

FWShape *fw_chamfer(const FWShape *s, const int32_t *edges, int32_t count, double distance,
                    FWError *err) {
  FW_TRY
  const TopTools_IndexedMapOfShape &map = s->edges();
  BRepFilletAPI_MakeChamfer mk(s->shape);
  for (int i = 0; i < count; i++)
    if (edges[i] >= 1 && edges[i] <= map.Extent()) mk.Add(distance, TopoDS::Edge(map(edges[i])));
  mk.Build();
  if (!mk.IsDone()) { setError(err, "chamfer too large for this edge"); return nullptr; }
  return wrap(mk.Shape());
  FW_CATCH(nullptr)
}

FWShape *fw_shell(const FWShape *s, const int32_t *openFaces, int32_t count, double thickness,
                  FWError *err) {
  FW_TRY
  if (count == 0) {
    // A closed hollow body: offset inwards and cut the inside away.
    BRepOffsetAPI_MakeOffsetShape off;
    off.PerformByJoin(s->shape, -thickness, 1e-4);
    if (!off.IsDone()) { setError(err, "wall too thick for this body"); return nullptr; }
    BRepAlgoAPI_Cut cut(s->shape, off.Shape());
    if (!cut.IsDone() || cut.HasErrors()) { setError(err, "hollow failed"); return nullptr; }
    return wrap(cut.Shape());
  }
  const TopTools_IndexedMapOfShape &map = s->faces();
  TopTools_ListOfShape remove;
  for (int i = 0; i < count; i++)
    if (openFaces[i] >= 1 && openFaces[i] <= map.Extent()) remove.Append(map(openFaces[i]));
  BRepOffsetAPI_MakeThickSolid mk;
  mk.MakeThickSolidByJoin(s->shape, remove, -thickness, 1e-4);
  if (!mk.IsDone()) { setError(err, "wall too thick for this body"); return nullptr; }
  return wrap(mk.Shape());
  FW_CATCH(nullptr)
}

FWShape *fw_push_pull(const FWShape *s, int32_t face, double distance, FWError *err) {
  FW_TRY
  const TopTools_IndexedMapOfShape &map = s->faces();
  if (face < 1 || face > map.Extent()) { setError(err, "face not found"); return nullptr; }
  TopoDS_Face f = TopoDS::Face(map(face));
  BRepAdaptor_Surface surf(f);
  if (surf.GetType() != GeomAbs_Plane) { setError(err, "only flat faces can be pushed or pulled"); return nullptr; }
  gp_Dir n = surf.Plane().Axis().Direction();
  if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
  BRepPrimAPI_MakePrism prism(f, gp_Vec(n) * distance);
  if (!prism.IsDone()) { setError(err, "push/pull failed"); return nullptr; }
  TopoDS_Shape r;
  if (distance > 0) {
    BRepAlgoAPI_Fuse op(s->shape, prism.Shape());
    if (!op.IsDone() || op.HasErrors()) { setError(err, "push/pull failed"); return nullptr; }
    r = op.Shape();
  } else {
    BRepAlgoAPI_Cut op(s->shape, prism.Shape());
    if (!op.IsDone() || op.HasErrors()) { setError(err, "push/pull failed"); return nullptr; }
    r = op.Shape();
  }
  return wrap(clean(r));
  FW_CATCH(nullptr)
}

FWShape *fw_transform(const FWShape *s, const double *m, FWError *err) {
  FW_TRY
  gp_Trsf t;
  t.SetValues(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
  return wrap(BRepBuilderAPI_Transform(s->shape, t, true).Shape());
  FW_CATCH(nullptr)
}

FWShape *fw_mirror(const FWShape *s, FWPlane plane, FWError *err) {
  FW_TRY
  gp_Trsf t;
  t.SetMirror(gp_Ax2(P(plane.origin), D(plane.normal)));
  return wrap(BRepBuilderAPI_Transform(s->shape, t, true).Shape());
  FW_CATCH(nullptr)
}

FWShape *fw_hole_tool(FWVec3 point, FWVec3 direction, double diameter, double depth,
                      double cbDiameter, double cbDepth, double csDiameter, FWError *err) {
  FW_TRY
  gp_Dir dir = D(direction);
  const double lead = 0.05;  // start just outside the face so the cut never lands exactly on it
  double d = depth > 0 ? depth : 10000.0;
  gp_Pnt start = P(point).Translated(gp_Vec(dir) * -lead);
  TopoDS_Shape tool = BRepPrimAPI_MakeCylinder(gp_Ax2(start, dir), diameter / 2, d + lead).Shape();
  if (cbDiameter > diameter && cbDepth > 0) {
    TopoDS_Shape cb = BRepPrimAPI_MakeCylinder(gp_Ax2(start, dir), cbDiameter / 2, cbDepth + lead).Shape();
    tool = BRepAlgoAPI_Fuse(tool, cb).Shape();
  } else if (csDiameter > diameter) {
    double h = (csDiameter - diameter) / 2;  // 90° countersink
    TopoDS_Shape cone = BRepPrimAPI_MakeCone(gp_Ax2(start, dir), csDiameter / 2 + lead, diameter / 2, h + lead).Shape();
    tool = BRepAlgoAPI_Fuse(tool, cone).Shape();
  }
  return wrap(tool);
  FW_CATCH(nullptr)
}

FWShape *fw_split(const FWShape *s, FWPlane plane, FWError *err) {
  FW_TRY
  TopoDS_Face cutter = BRepBuilderAPI_MakeFace(gp_Pln(axes(plane)), -1e5, 1e5, -1e5, 1e5).Face();
  BRepAlgoAPI_Splitter sp;
  TopTools_ListOfShape args, tools;
  args.Append(s->shape);
  tools.Append(cutter);
  sp.SetArguments(args);
  sp.SetTools(tools);
  sp.Build();
  if (!sp.IsDone() || sp.HasErrors()) { setError(err, "split failed"); return nullptr; }
  return wrap(sp.Shape());
  FW_CATCH(nullptr)
}

// MARK: - Topology

int32_t fw_solid_count(const FWShape *s) { return s ? s->solids().Extent() : 0; }

FWShape *fw_solid_at(const FWShape *s, int32_t index) {
  const TopTools_IndexedMapOfShape &m = s->solids();
  if (index < 1 || index > m.Extent()) return nullptr;
  return wrap(m(index));
}

int32_t fw_face_count(const FWShape *s) { return s ? s->faces().Extent() : 0; }
int32_t fw_edge_count(const FWShape *s) { return s ? s->edges().Extent() : 0; }

bool fw_face_info(const FWShape *s, int32_t face, FWFaceInfo *out) {
  try {
    const TopTools_IndexedMapOfShape &map = s->faces();
    if (face < 1 || face > map.Extent()) return false;
    TopoDS_Face f = TopoDS::Face(map(face));
    std::memset(out, 0, sizeof(FWFaceInfo));
    GProp_GProps props;
    BRepGProp::SurfaceProperties(f, props);
    out->area = props.Mass();
    gp_Pnt c = props.CentreOfMass();
    BRepAdaptor_Surface surf(f);
    // Normal at the point of the face closest to its centre of mass.
    Handle(Geom_Surface) gs = BRep_Tool::Surface(f);
    ShapeAnalysis_Surface sas(gs);
    gp_Pnt2d uv = sas.ValueOfUV(c, 1e-6);
    BRepLProp_SLProps lp(surf, uv.X(), uv.Y(), 1, 1e-6);
    gp_Dir n = lp.IsNormalDefined() ? lp.Normal() : gp_Dir(0, 0, 1);
    if (f.Orientation() == TopAbs_REVERSED) n.Reverse();
    gp_Pnt onFace = surf.Value(uv.X(), uv.Y());
    out->centroid = F(c);
    out->normal = F(n);
    switch (surf.GetType()) {
      case GeomAbs_Plane: {
        out->kind = FWSurfPlane;
        gp_Pln pl = surf.Plane();
        gp_Dir pn = pl.Axis().Direction();
        if (f.Orientation() == TopAbs_REVERSED) pn.Reverse();
        out->normal = F(pn);
        out->plane.origin = F(c);
        out->plane.normal = F(pn);
        out->plane.xDir = F(pl.XAxis().Direction());
        break;
      }
      case GeomAbs_Cylinder:
        out->kind = FWSurfCylinder;
        out->axis = F(surf.Cylinder().Axis().Direction());
        out->radius = surf.Cylinder().Radius();
        out->centroid = F(onFace);
        break;
      case GeomAbs_Cone:
        out->kind = FWSurfCone;
        out->axis = F(surf.Cone().Axis().Direction());
        out->centroid = F(onFace);
        break;
      case GeomAbs_Sphere:
        out->kind = FWSurfSphere;
        out->radius = surf.Sphere().Radius();
        break;
      case GeomAbs_Torus:
        out->kind = FWSurfTorus;
        out->axis = F(surf.Torus().Axis().Direction());
        out->radius = surf.Torus().MinorRadius();
        break;
      default:
        out->kind = FWSurfOther;
        out->centroid = F(onFace);
    }
    return true;
  } catch (...) {
    return false;
  }
}

bool fw_edge_info(const FWShape *s, int32_t edge, FWEdgeInfo *out) {
  try {
    const TopTools_IndexedMapOfShape &map = s->edges();
    if (edge < 1 || edge > map.Extent()) return false;
    TopoDS_Edge e = TopoDS::Edge(map(edge));
    std::memset(out, 0, sizeof(FWEdgeInfo));
    if (BRep_Tool::Degenerated(e)) return false;
    BRepAdaptor_Curve c(e);
    double a = c.FirstParameter(), b = c.LastParameter();
    out->start = F(c.Value(a));
    out->end = F(c.Value(b));
    out->midpoint = F(c.Value((a + b) / 2));
    out->length = GCPnts_AbscissaPoint::Length(c);
    if (c.GetType() == GeomAbs_Line) out->kind = FWCurveLine;
    else if (c.GetType() == GeomAbs_Circle) {
      out->kind = FWCurveCircle;
      out->center = F(c.Circle().Location());
      out->radius = c.Circle().Radius();
    } else out->kind = FWCurveOther;
    return true;
  } catch (...) {
    return false;
  }
}

void fw_edge_faces(const FWShape *s, int32_t edge, int32_t *faceA, int32_t *faceB) {
  *faceA = 0; *faceB = 0;
  const TopTools_IndexedMapOfShape &edges = s->edges();
  const TopTools_IndexedMapOfShape &faces = s->faces();
  if (edge < 1 || edge > edges.Extent()) return;
  const TopTools_ListOfShape *list = s->ancestors().Seek(edges(edge));
  if (!list) return;
  int n = 0;
  for (TopTools_ListOfShape::Iterator it(*list); it.More(); it.Next()) {
    int idx = faces.FindIndex(it.Value());
    if (n == 0) *faceA = idx; else if (n == 1) *faceB = idx;
    n++;
  }
}

int32_t fw_face_edges(const FWShape *s, int32_t face, int32_t *out, int32_t max) {
  const TopTools_IndexedMapOfShape &faces = s->faces();
  const TopTools_IndexedMapOfShape &edges = s->edges();
  if (face < 1 || face > faces.Extent()) return 0;
  TopTools_IndexedMapOfShape faceEdges = mapOf(faces(face), TopAbs_EDGE);
  int n = 0;
  for (int i = 1; i <= faceEdges.Extent(); i++) {
    if (n < max) out[n] = edges.FindIndex(faceEdges(i));
    n++;
  }
  return n;
}

FWProps fw_props(const FWShape *s) {
  FWProps p;
  std::memset(&p, 0, sizeof(p));
  try {
    GProp_GProps vol, surf;
    BRepGProp::VolumeProperties(s->shape, vol);
    BRepGProp::SurfaceProperties(s->shape, surf);
    p.volume = std::fabs(vol.Mass());
    p.area = surf.Mass();
    p.centerOfMass = F(vol.CentreOfMass());
    Bnd_Box box;
    BRepBndLib::AddOptimal(s->shape, box, false, false);
    if (!box.IsVoid()) {
      double x0, y0, z0, x1, y1, z1;
      box.Get(x0, y0, z0, x1, y1, z1);
      p.bboxMin = FWVec3{x0, y0, z0};
      p.bboxMax = FWVec3{x1, y1, z1};
    }
  } catch (...) {}
  return p;
}

bool fw_is_valid_solid(const FWShape *s) {
  try {
    if (!s || s->shape.IsNull()) return false;
    if (mapOf(s->shape, TopAbs_SOLID).Extent() == 0) return false;
    BRepCheck_Analyzer check(s->shape);
    if (!check.IsValid()) return false;
    ShapeAnalysis_FreeBounds free(s->shape, 1e-5, false, false);
    TopTools_IndexedMapOfShape closedWires = mapOf(free.GetClosedWires(), TopAbs_EDGE);
    TopTools_IndexedMapOfShape openWires = mapOf(free.GetOpenWires(), TopAbs_EDGE);
    return closedWires.Extent() == 0 && openWires.Extent() == 0;
  } catch (...) {
    return false;
  }
}

static TopoDS_Shape subShape(const FWShape *s, int32_t kind, int32_t index) {
  if (kind == 1) {
    const TopTools_IndexedMapOfShape &m = s->faces();
    if (index >= 1 && index <= m.Extent()) return m(index);
  } else if (kind == 2) {
    const TopTools_IndexedMapOfShape &m = s->edges();
    if (index >= 1 && index <= m.Extent()) return m(index);
  }
  return s->shape;
}

double fw_distance(const FWShape *a, int32_t kindA, int32_t indexA,
                   const FWShape *b, int32_t kindB, int32_t indexB,
                   FWVec3 *pointA, FWVec3 *pointB) {
  try {
    BRepExtrema_DistShapeShape d(subShape(a, kindA, indexA), subShape(b, kindB, indexB));
    if (!d.IsDone() || d.NbSolution() < 1) return -1;
    if (pointA) *pointA = F(d.PointOnShape1(1));
    if (pointB) *pointB = F(d.PointOnShape2(1));
    return d.Value();
  } catch (...) {
    return -1;
  }
}

// MARK: - Tessellation

FWMesh *fw_tessellate(const FWShape *s, double linear, double angular) {
  FWMesh *mesh = new FWMesh();
  try {
    BRepMesh_IncrementalMesh(s->shape, linear, false, angular, true);
    const TopTools_IndexedMapOfShape &faces = s->faces();
    for (int fi = 1; fi <= faces.Extent(); fi++) {
      TopoDS_Face f = TopoDS::Face(faces(fi));
      TopLoc_Location loc;
      Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(f, loc);
      if (tri.IsNull()) continue;
      if (!tri->HasNormals()) BRepLib_ToolTriangulatedShape::ComputeNormals(f, tri);
      bool reversed = f.Orientation() == TopAbs_REVERSED;
      gp_Trsf t = loc.Transformation();
      uint32_t base = (uint32_t)(mesh->positions.size() / 3);
      for (int i = 1; i <= tri->NbNodes(); i++) {
        gp_Pnt p = tri->Node(i).Transformed(t);
        gp_Dir n = tri->HasNormals() ? tri->Normal(i) : gp_Dir(0, 0, 1);
        n.Transform(t);
        if (reversed) n.Reverse();
        mesh->positions.insert(mesh->positions.end(), {(float)p.X(), (float)p.Y(), (float)p.Z()});
        mesh->normals.insert(mesh->normals.end(), {(float)n.X(), (float)n.Y(), (float)n.Z()});
        mesh->vertexFaces.push_back(fi);
      }
      for (int i = 1; i <= tri->NbTriangles(); i++) {
        int a, b, c;
        tri->Triangle(i).Get(a, b, c);
        if (reversed) std::swap(b, c);
        mesh->indices.insert(mesh->indices.end(), {base + a - 1, base + b - 1, base + c - 1});
      }
    }
    // Edges: skip seams (a cylinder's join line), they are not real edges for the user.
    const TopTools_IndexedMapOfShape &edges = s->edges();
    const TopTools_IndexedDataMapOfShapeListOfShape &anc = s->ancestors();
    for (int ei = 1; ei <= edges.Extent(); ei++) {
      TopoDS_Edge e = TopoDS::Edge(edges(ei));
      if (BRep_Tool::Degenerated(e)) continue;
      const TopTools_ListOfShape *list = anc.Seek(e);
      bool seam = false;
      if (list && list->Extent() == 1) seam = BRep_Tool::IsClosed(e, TopoDS::Face(list->First()));
      if (seam) continue;
      BRepAdaptor_Curve c(e);
      GCPnts_TangentialDeflection disc(c, angular, linear, 2);
      int n = disc.NbPoints();
      if (n < 2) continue;
      for (int i = 1; i <= n; i++) {
        gp_Pnt p = disc.Value(i);
        mesh->edgePoints.insert(mesh->edgePoints.end(), {(float)p.X(), (float)p.Y(), (float)p.Z()});
      }
      mesh->edgeSizes.push_back(n);
      mesh->edgeIds.push_back(ei);
    }
  } catch (...) {}
  return mesh;
}

void fw_mesh_free(FWMesh *m) { delete m; }
int32_t fw_mesh_vertex_count(const FWMesh *m) { return (int32_t)(m->positions.size() / 3); }
int32_t fw_mesh_triangle_count(const FWMesh *m) { return (int32_t)(m->indices.size() / 3); }
const float *fw_mesh_positions(const FWMesh *m) { return m->positions.data(); }
const float *fw_mesh_normals(const FWMesh *m) { return m->normals.data(); }
const uint32_t *fw_mesh_indices(const FWMesh *m) { return m->indices.data(); }
const int32_t *fw_mesh_vertex_faces(const FWMesh *m) { return m->vertexFaces.data(); }
int32_t fw_mesh_edge_point_count(const FWMesh *m) { return (int32_t)(m->edgePoints.size() / 3); }
const float *fw_mesh_edge_points(const FWMesh *m) { return m->edgePoints.data(); }
int32_t fw_mesh_edge_polyline_count(const FWMesh *m) { return (int32_t)m->edgeSizes.size(); }
const int32_t *fw_mesh_edge_polyline_sizes(const FWMesh *m) { return m->edgeSizes.data(); }
const int32_t *fw_mesh_edge_polyline_ids(const FWMesh *m) { return m->edgeIds.data(); }

// MARK: - Exchange

bool fw_write_step(const FWShape *const *shapes, int32_t count, const char *path, FWError *err) {
  FW_TRY
  STEPControl_Writer w;
  Interface_Static::SetCVal("write.step.unit", "MM");
  Interface_Static::SetCVal("write.step.schema", "AP214IS");
  for (int i = 0; i < count; i++) {
    if (w.Transfer(shapes[i]->shape, STEPControl_AsIs) != IFSelect_RetDone) {
      setError(err, "could not convert body to STEP");
      return false;
    }
  }
  if (w.Write(path) != IFSelect_RetDone) { setError(err, "could not write file"); return false; }
  return true;
  FW_CATCH(false)
}

FWShape *fw_read_step(const char *path, FWError *err) {
  FW_TRY
  STEPControl_Reader r;
  if (r.ReadFile(path) != IFSelect_RetDone) { setError(err, "not a readable STEP file"); return nullptr; }
  r.TransferRoots();
  TopoDS_Shape s = r.OneShape();
  if (s.IsNull()) { setError(err, "the file has no solids"); return nullptr; }
  ShapeFix_Shape fix(s);
  fix.Perform();
  return wrap(fix.Shape());
  FW_CATCH(nullptr)
}

char *fw_shape_to_brep(const FWShape *s, int64_t *length) {
  try {
    std::ostringstream os;
    BRepTools::Write(s->shape, os, false, false, TopTools_FormatVersion_CURRENT);
    std::string str = os.str();
    char *buf = (char *)std::malloc(str.size());
    std::memcpy(buf, str.data(), str.size());
    *length = (int64_t)str.size();
    return buf;
  } catch (...) {
    *length = 0;
    return nullptr;
  }
}

FWShape *fw_shape_from_brep(const char *data, int64_t length, FWError *err) {
  FW_TRY
  std::istringstream is(std::string(data, (size_t)length));
  TopoDS_Shape s;
  BRep_Builder b;
  BRepTools::Read(s, is, b);
  if (s.IsNull()) { setError(err, "empty shape"); return nullptr; }
  return wrap(s);
  FW_CATCH(nullptr)
}

void fw_free_buffer(char *buffer) { std::free(buffer); }
