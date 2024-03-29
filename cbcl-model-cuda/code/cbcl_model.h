#ifndef __cbcl_model_h__
#define __cbcl_model_h__
#define IN 
#define OUT

#define ONHOST       0
#define ONDEVICE     1


__host__ __device__ float* elptr(float* base,int depth,int row,int col,int height,int pitch);
typedef struct{
  int    __align__(8) height;
  int    __align__(8) width;
  int    __align__(8) depth;  
  int    __align__(8) pitch;
  float  __align__(8) *ptr;
  int    __align__(8) where;
}band_info;

	 void gpu_s_norm_filter(
		IN  band_info	*pc,     /*pointer to the DEVICE storage*/
		IN  int			in_bands,  /*number of input bands [IN]*/
		IN  band_info	*pfilt,  /*pointer to DEVICE storage*/
		IN  int			num_filt,  /*number of filtes=output depth*/
		OUT band_info	**pps,      /*pointer ot DEVICE storage*/
		OUT int			*pout_bands,/*number of output bands*/
        IN  bool        copy=true   /*copy output to host*/
	   );


	 void gpu_s_rbf(
		IN  band_info	*pc,     /*pointer to the DEVICE storage*/
		IN  int			in_bands,  /*number of input bands [IN]*/
		IN  band_info	*pfilt,  /*pointer to DEVICE storage*/
		IN  int			num_filt,  /*number of filtes=output depth*/
        IN  float       sigma,      /*sigma for the tuning curve*/
		OUT band_info	**pps,      /*pointer ot DEVICE storage*/
		OUT int			*pout_bands,/*number of output bands*/
        IN  bool        copy=true  /*copy results back to host*/
	   );

void gpu_c_local(
		IN  band_info* s,     /*pointer to DEVICE storage*/
		IN  int in_bands,     /*number of input bands*/
		IN  int pool_xy,      /*spatial pooling: subsampling by pool_xy/2*/
		IN  int step_xy,      /*spatial subsampling factor*/
        IN  int pool_scale,   /*scale wise pooling: out_bands=in_bands/pool_scale*/
        IN  int step_scale,   /*scale incremenet step*/
		OUT band_info** c,   /*pointer to DEVICE storage*/
		OUT int* out_bands,   /*number of output bands*/
        IN  bool copy=true    /*copy results back to host*/
	);

	void gpu_c_global(
		IN band_info* s,      /*pointer to device storage*/
		IN int in_bands,      /*number of input bands*/
		OUT int* out_units,   /*=input depth*/
		OUT float* c          /*pointer to DEVICE storage*/
		);

	void cpu_c_global(
	IN band_info* s,      /*pointer to device storage*/
	IN int in_bands,      /*number of input bands*/
	OUT float** ppc,      /*pointer to DEVICE storage*/
	OUT int* out_units   /*=input depth*/	
	);

    void cpu_create_c0(
    IN  float* pimg,            /*pointer to image data*/
    IN  int width,              /*width of the image*/
    IN  int height,             /*height of the image*/
    OUT band_info** ppc,        /*pointer to host storage*/
    OUT int* pbands,             /*number of bands*/
    IN  float scale=1.113,       /*resize scale*/
    IN  int   num_scales=16      /*number of scales*/
    );
    
    void gpu_create_c0(
    IN  float* pimg,            /*pointer to image data*/
    IN  int width,              /*width of the image*/
    IN  int height,             /*height of the image*/
    OUT band_info** ppc,        /*pointer to host storage*/
    OUT int* pbands,             /*number of bands*/
    IN  float scale=1.113,       /*resize scale*/
    IN  int   num_scales=16,      /*number of scales*/
    IN  bool  copy      =true    /*copy output to host*/
    );

     void cpu_release_images(
        IN  band_info** ppbands, /*pointer to HOST storage*/
        OUT int num_bands        /*number of bands*/
    );
#endif
