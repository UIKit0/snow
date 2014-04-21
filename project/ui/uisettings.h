/**************************************************************************
**
**   SNOW - CS224 BROWN UNIVERSITY
**
**   databinding.h
**   Authors: evjang, mliberma, taparson, wyegelwe
**   Created: 17 Apr 2014
**
**************************************************************************/

#ifndef UISETTINGS_H
#define UISETTINGS_H

#define DEFINE_SETTING( TYPE, NAME )                            \
    private:                                                    \
        TYPE m_##NAME;                                          \
    public:                                                     \
        static TYPE& NAME() { return instance()->m_##NAME; }    \


#include <QPoint>
#include <QSize>

#ifndef GLM_FORCE_RADIANS
    #define GLM_FORCE_RADIANS
#endif
#include "glm/vec3.hpp"
#include "glm/vec4.hpp"
#include "glm/mat4x4.hpp"

#include "cuda/vector.cu"

struct Grid;

class UiSettings
{

public:

    enum MeshMode
    {
        WIREFRAME,
        SOLID,
        SOLID_AND_WIREFRAME
    };

    enum GridMode
    {
        BOX,
        HALF_CELLS,
        FULL_CELLS
    };

    enum GridDataMode
    {
        NODE_MASS,
        NODE_VELOCITY,
        NODE_SPEED,
        NODE_FORCE
    };

    enum ParticlesMode
    {
        PARTICLE_MASS,
        PARTICLE_VELOCITY,
        PARTICLE_SPEED
    };

public:

    static UiSettings* instance();
    static void deleteInstance();

    static void loadSettings();
    static void saveSettings();

    static Grid buildGrid( const glm::mat4 &ctm );

protected:

    UiSettings() {}
    virtual ~UiSettings() {}

private:

    static UiSettings *INSTANCE;

    DEFINE_SETTING( QPoint, windowPosition )
    DEFINE_SETTING( QSize, windowSize )

    DEFINE_SETTING( int, fillNumParticles )
    DEFINE_SETTING( float, fillResolution )

    DEFINE_SETTING( bool, exportSimulation )

    DEFINE_SETTING( vec3, gridPosition )
    DEFINE_SETTING( glm::ivec3, gridDimensions )
    DEFINE_SETTING( float, gridResolution )

    DEFINE_SETTING( bool, showMesh )
    DEFINE_SETTING( int, showMeshMode )
    DEFINE_SETTING( bool, showGrid )
    DEFINE_SETTING( int, showGridMode )
    DEFINE_SETTING( bool, showGridData )
    DEFINE_SETTING( int, showGridDataMode )
    DEFINE_SETTING( bool, showParticles )
    DEFINE_SETTING( int, showParticlesMode )

    DEFINE_SETTING( glm::vec4, selectionColor )

};

#endif // UISETTINGS_H
