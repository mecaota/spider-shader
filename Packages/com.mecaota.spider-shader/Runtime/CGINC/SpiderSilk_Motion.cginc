#ifndef SPIDER_SILK_MOTION_INCLUDED
#define SPIDER_SILK_MOTION_INCLUDED

// Shared elastic rhythm. Bounded [-1,1], no accumulated simulation state.
// phase is constant per strand/span; coordinate is measured along that span.
float SSM_ElasticWave(float coordinate, float waves, float time, float phase)
{
    float p = coordinate * max(waves, 0.0) * 6.28318530718 + phase;
    return 0.72 * sin(time + p) + 0.28 * sin(time * 1.63 - p * 0.73 + 1.7);
}

// Exactly zero at BOTH attachments, including UV outside the span.
float SSM_PinEnvelope(float along)
{
    float t = saturate(along);
    return 4.0 * t * (1.0 - t);
}

// A hanging thread always stays below its un-deformed path. Amount in metres.
float SSM_GravitySag(float along, float amount, float oscillation,
                     float waves, float time, float phase)
{
    return max(amount, 0.0) * SSM_PinEnvelope(along)
         * (1.0 + saturate(oscillation) * SSM_ElasticWave(along, waves, time, phase));
}
#endif
