//
//  simd+Extensions.swift
//  SnapMeasure
//

import simd
import Foundation

// MARK: - SIMD3<Float> Extensions

extension SIMD3 where Scalar == Float {
    /// Compute the magnitude (length) of the vector
    var magnitude: Float {
        simd_length(self)
    }

    /// Return a normalized version of the vector
    var normalized: SIMD3<Float> {
        simd_normalize(self)
    }

    /// Cross product with another vector
    func cross(_ other: SIMD3<Float>) -> SIMD3<Float> {
        simd_cross(self, other)
    }

    /// Dot product with another vector
    func dot(_ other: SIMD3<Float>) -> Float {
        simd_dot(self, other)
    }
}

// MARK: - Matrix Operations

extension simd_float3x3 {
    /// Create a rotation matrix from axis and angle
    static func rotation(axis: SIMD3<Float>, angle: Float) -> simd_float3x3 {
        let c = cos(angle)
        let s = sin(angle)
        let t = 1 - c

        let x = axis.x
        let y = axis.y
        let z = axis.z

        return simd_float3x3(
            SIMD3<Float>(t * x * x + c,     t * x * y + s * z, t * x * z - s * y),
            SIMD3<Float>(t * x * y - s * z, t * y * y + c,     t * y * z + s * x),
            SIMD3<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c)
        )
    }

    /// Transpose of the matrix
    var transposed: simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(columns.0.x, columns.1.x, columns.2.x),
            SIMD3<Float>(columns.0.y, columns.1.y, columns.2.y),
            SIMD3<Float>(columns.0.z, columns.1.z, columns.2.z)
        )
    }
}

// MARK: - Quaternion Extensions

extension simd_quatf {
    /// Create quaternion from rotation matrix
    init(rotationMatrix m: simd_float3x3) {
        let trace = m.columns.0.x + m.columns.1.y + m.columns.2.z

        if trace > 0 {
            let s = 0.5 / sqrt(trace + 1.0)
            let w = 0.25 / s
            let x = (m.columns.1.z - m.columns.2.y) * s
            let y = (m.columns.2.x - m.columns.0.z) * s
            let z = (m.columns.0.y - m.columns.1.x) * s
            self.init(ix: x, iy: y, iz: z, r: w)
        } else if m.columns.0.x > m.columns.1.y && m.columns.0.x > m.columns.2.z {
            let s = 2.0 * sqrt(1.0 + m.columns.0.x - m.columns.1.y - m.columns.2.z)
            let w = (m.columns.1.z - m.columns.2.y) / s
            let x = 0.25 * s
            let y = (m.columns.1.x + m.columns.0.y) / s
            let z = (m.columns.2.x + m.columns.0.z) / s
            self.init(ix: x, iy: y, iz: z, r: w)
        } else if m.columns.1.y > m.columns.2.z {
            let s = 2.0 * sqrt(1.0 + m.columns.1.y - m.columns.0.x - m.columns.2.z)
            let w = (m.columns.2.x - m.columns.0.z) / s
            let x = (m.columns.1.x + m.columns.0.y) / s
            let y = 0.25 * s
            let z = (m.columns.2.y + m.columns.1.z) / s
            self.init(ix: x, iy: y, iz: z, r: w)
        } else {
            let s = 2.0 * sqrt(1.0 + m.columns.2.z - m.columns.0.x - m.columns.1.y)
            let w = (m.columns.0.y - m.columns.1.x) / s
            let x = (m.columns.2.x + m.columns.0.z) / s
            let y = (m.columns.2.y + m.columns.1.z) / s
            let z = 0.25 * s
            self.init(ix: x, iy: y, iz: z, r: w)
        }
    }

    /// Convert to rotation matrix
    var rotationMatrix: simd_float3x3 {
        let qx = self.imag.x
        let qy = self.imag.y
        let qz = self.imag.z
        let qw = self.real

        let xx = qx * qx
        let yy = qy * qy
        let zz = qz * qz
        let xy = qx * qy
        let xz = qx * qz
        let yz = qy * qz
        let wx = qw * qx
        let wy = qw * qy
        let wz = qw * qz

        return simd_float3x3(
            SIMD3<Float>(1 - 2 * (yy + zz), 2 * (xy + wz),     2 * (xz - wy)),
            SIMD3<Float>(2 * (xy - wz),     1 - 2 * (xx + zz), 2 * (yz + wx)),
            SIMD3<Float>(2 * (xz + wy),     2 * (yz - wx),     1 - 2 * (xx + yy))
        )
    }
}

// MARK: - Eigen Decomposition for 3x3 Symmetric Matrix

/// Compute eigenvalues and eigenvectors of a 3x3 symmetric matrix using Jacobi iteration
func eigenDecomposition(_ matrix: simd_float3x3) -> (eigenvalues: SIMD3<Float>, eigenvectors: simd_float3x3) {
    var a = matrix
    var v = simd_float3x3(1) // Identity matrix

    let maxIterations = 50
    let tolerance: Float = 1e-10

    for _ in 0..<maxIterations {
        // Find the largest off-diagonal element
        var maxVal: Float = 0
        var p = 0
        var q = 1

        for i in 0..<3 {
            for j in (i+1)..<3 {
                let val = abs(a[j][i])
                if val > maxVal {
                    maxVal = val
                    p = i
                    q = j
                }
            }
        }

        if maxVal < tolerance {
            break
        }

        // Compute rotation angle
        let diff = a[q][q] - a[p][p]
        var t: Float
        if abs(diff) < tolerance {
            t = 1
        } else {
            let phi = diff / (2 * a[q][p])
            t = 1 / (abs(phi) + sqrt(phi * phi + 1))
            if phi < 0 { t = -t }
        }

        let c = 1 / sqrt(t * t + 1)
        let s = t * c

        // Apply rotation to a
        let app = a[p][p]
        let aqq = a[q][q]
        let apq = a[q][p]

        a[p][p] = c * c * app - 2 * s * c * apq + s * s * aqq
        a[q][q] = s * s * app + 2 * s * c * apq + c * c * aqq
        a[q][p] = 0
        a[p][q] = 0

        for i in 0..<3 {
            if i != p && i != q {
                let aip = a[p][i]
                let aiq = a[q][i]
                a[p][i] = c * aip - s * aiq
                a[i][p] = a[p][i]
                a[q][i] = s * aip + c * aiq
                a[i][q] = a[q][i]
            }
        }

        // Apply rotation to v (eigenvectors)
        for i in 0..<3 {
            let vip = v[p][i]
            let viq = v[q][i]
            v[p][i] = c * vip - s * viq
            v[q][i] = s * vip + c * viq
        }
    }

    // Extract eigenvalues and sort them (descending)
    var eigenvalues = SIMD3<Float>(a[0][0], a[1][1], a[2][2])
    var eigenvectors = v

    // Sort by eigenvalue (descending)
    let indices = [0, 1, 2].sorted { eigenvalues[$0] > eigenvalues[$1] }

    eigenvalues = SIMD3<Float>(eigenvalues[indices[0]], eigenvalues[indices[1]], eigenvalues[indices[2]])
    eigenvectors = simd_float3x3(
        v[indices[0]],
        v[indices[1]],
        v[indices[2]]
    )

    return (eigenvalues, eigenvectors)
}
