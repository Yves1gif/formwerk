// FWKernel: the plain C interface between Formwerk and Open CASCADE.
//
// Only Kernel/*.cpp include OCCT headers. Swift sees opaque handles and plain structs,
// which keeps the Swift compiler away from OCCT's heavy C++ templates.
// All lengths are millimetres, all angles radians.
// Functions that can fail return NULL / false and write a message into `err` (may be NULL).

#ifndef FWKERNEL_H
#define FWKERNEL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FWShape FWShape;   // a TopoDS_Shape (solid, compound, face…)
typedef struct FWMesh FWMesh;     // a tessellation of a shape

typedef struct { double x, y, z; } FWVec3;
typedef struct { double x, y; } FWVec2;

/// A plane with its own 2D coordinate system: u = xDir, v = normal × xDir.
typedef struct { FWVec3 origin, normal, xDir; } FWPlane;

typedef struct { char message[256]; } FWError;

typedef enum { FWSegLine = 0, FWSegArc = 1, FWSegCircle = 2 } FWSegKind;

/// One piece of a sketch loop, in plane coordinates.
/// Line: a → b. Arc: a = start, b = a point on the arc, c = end. Circle: a = centre, b.x = radius.
typedef struct { int32_t kind; FWVec2 a, b, c; } FWSegment;

typedef enum { FWBoolUnion = 0, FWBoolCut = 1, FWBoolIntersect = 2 } FWBoolOp;

typedef enum {
  FWSurfPlane = 0, FWSurfCylinder = 1, FWSurfCone = 2, FWSurfSphere = 3,
  FWSurfTorus = 4, FWSurfOther = 5
} FWSurfaceKind;

typedef enum { FWCurveLine = 0, FWCurveCircle = 1, FWCurveOther = 2 } FWCurveKind;

typedef struct {
  int32_t kind;          // FWSurfaceKind
  FWVec3 centroid;       // centre of mass of the face
  FWVec3 normal;         // outward normal at the centroid (planes: the plane normal)
  FWVec3 axis;           // cylinders/cones: axis direction
  double area;
  double radius;         // cylinders/spheres
  FWPlane plane;         // planes: a sketch plane lying on the face (origin = centroid)
} FWFaceInfo;

typedef struct {
  int32_t kind;          // FWCurveKind
  FWVec3 midpoint;
  FWVec3 start, end;
  FWVec3 center;         // circles
  double length;
  double radius;         // circles
} FWEdgeInfo;

typedef struct {
  double volume, area;
  FWVec3 centerOfMass;
  FWVec3 bboxMin, bboxMax;
} FWProps;

// MARK: Lifetime
void fw_shape_free(FWShape *s);
FWShape *fw_shape_copy(const FWShape *s);
bool fw_shape_is_null(const FWShape *s);

// MARK: Building
/// A planar face from loops. The first loop is the outer boundary, the rest are holes.
/// loopSizes[i] = number of segments in loop i; segments are stored loop after loop.
FWShape *fw_make_face(FWPlane plane, const FWSegment *segments, const int32_t *loopSizes,
                      int32_t loopCount, FWError *err);
FWShape *fw_make_box(FWVec3 corner, FWVec3 size, FWError *err);
FWShape *fw_make_cylinder(FWVec3 base, FWVec3 axis, double radius, double height, FWError *err);
/// Combines several shapes into one compound (e.g. all faces of a sketch region set).
FWShape *fw_make_compound(const FWShape *const *shapes, int32_t count);

// MARK: Features
/// Sweeps a face (or compound of faces) along `direction` by `distance` (negative = opposite).
/// symmetric: half the distance each way.
FWShape *fw_extrude(const FWShape *profile, FWVec3 direction, double distance, bool symmetric,
                    FWError *err);
FWShape *fw_revolve(const FWShape *profile, FWVec3 axisOrigin, FWVec3 axisDir, double angle,
                    FWError *err);
FWShape *fw_boolean(const FWShape *a, const FWShape *b, int32_t op, FWError *err);
/// Fillets the given edges (1-based indices from fw_edge_count order).
FWShape *fw_fillet(const FWShape *s, const int32_t *edges, int32_t count, double radius,
                   FWError *err);
FWShape *fw_chamfer(const FWShape *s, const int32_t *edges, int32_t count, double distance,
                    FWError *err);
/// Hollows a solid. `openFaces` (1-based) are removed; with none, the result is a closed hollow body.
/// Positive thickness keeps the outside and grows the wall inwards.
FWShape *fw_shell(const FWShape *s, const int32_t *openFaces, int32_t count, double thickness,
                  FWError *err);
/// Moves one planar face along its normal by `distance` (push/pull). Positive = outwards.
FWShape *fw_push_pull(const FWShape *s, int32_t face, double distance, FWError *err);
/// Row-major 3x4 affine matrix (rotation + translation).
FWShape *fw_transform(const FWShape *s, const double *matrix12, FWError *err);
FWShape *fw_mirror(const FWShape *s, FWPlane plane, FWError *err);
/// A drilled hole: cylinder of `diameter` from `point` along `direction`, `depth` (<= 0 = through),
/// optional counterbore (cbDiameter, cbDepth) or countersink (csDiameter, 90°). Returns the tool body.
FWShape *fw_hole_tool(FWVec3 point, FWVec3 direction, double diameter, double depth,
                      double cbDiameter, double cbDepth, double csDiameter, FWError *err);
/// Splits a body with a plane into separate solids (returned as a compound).
FWShape *fw_split(const FWShape *s, FWPlane plane, FWError *err);

// MARK: Topology queries (indices are 1-based and stable for a given shape)
int32_t fw_solid_count(const FWShape *s);
/// Returns solid number i (1-based) as its own shape.
FWShape *fw_solid_at(const FWShape *s, int32_t index);
int32_t fw_face_count(const FWShape *s);
int32_t fw_edge_count(const FWShape *s);
bool fw_face_info(const FWShape *s, int32_t face, FWFaceInfo *out);
bool fw_edge_info(const FWShape *s, int32_t edge, FWEdgeInfo *out);
/// The two faces next to an edge (0 when there is only one).
void fw_edge_faces(const FWShape *s, int32_t edge, int32_t *faceA, int32_t *faceB);
/// Edges bounding a face. Writes up to `max` indices, returns the total.
int32_t fw_face_edges(const FWShape *s, int32_t face, int32_t *out, int32_t max);
FWProps fw_props(const FWShape *s);
/// True when the shape passes OCCT's validity check and every shell is closed.
bool fw_is_valid_solid(const FWShape *s);
/// Shortest distance between two sub-shapes (kind: 0 = whole shape, 1 = face, 2 = edge).
double fw_distance(const FWShape *a, int32_t kindA, int32_t indexA,
                   const FWShape *b, int32_t kindB, int32_t indexB,
                   FWVec3 *pointA, FWVec3 *pointB);

// MARK: Tessellation
/// linear: max chord deviation in mm. angular: max angle in radians.
FWMesh *fw_tessellate(const FWShape *s, double linear, double angular);
void fw_mesh_free(FWMesh *m);
int32_t fw_mesh_vertex_count(const FWMesh *m);
int32_t fw_mesh_triangle_count(const FWMesh *m);
/// xyz per vertex.
const float *fw_mesh_positions(const FWMesh *m);
const float *fw_mesh_normals(const FWMesh *m);
/// 3 indices per triangle.
const uint32_t *fw_mesh_indices(const FWMesh *m);
/// The 1-based face index of every vertex (vertices are never shared between faces).
const int32_t *fw_mesh_vertex_faces(const FWMesh *m);
/// Edge polylines: points (xyz) and, per polyline, its point count and edge index.
int32_t fw_mesh_edge_point_count(const FWMesh *m);
const float *fw_mesh_edge_points(const FWMesh *m);
int32_t fw_mesh_edge_polyline_count(const FWMesh *m);
const int32_t *fw_mesh_edge_polyline_sizes(const FWMesh *m);
const int32_t *fw_mesh_edge_polyline_ids(const FWMesh *m);

// MARK: Exchange
/// Writes STEP (AP214) to a file path.
bool fw_write_step(const FWShape *const *shapes, int32_t count, const char *path, FWError *err);
/// Reads a STEP file into one shape (a compound when there are several bodies).
FWShape *fw_read_step(const char *path, FWError *err);
/// OCCT's own text format, used for the shape cache. Returns a malloc'd buffer the caller frees.
char *fw_shape_to_brep(const FWShape *s, int64_t *length);
FWShape *fw_shape_from_brep(const char *data, int64_t length, FWError *err);
void fw_free_buffer(char *buffer);

#ifdef __cplusplus
}
#endif

#endif
