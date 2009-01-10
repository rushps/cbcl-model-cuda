#include "cuda.h"
#include "cutil.h"
#include <stdio.h>
#include <iostream>
#include <fstream>
#include <algorithm>
#include <assert.h>
#include "cbcl_model.h"

#define BLOCK_SIZE 16
#define MAXTHREADS 128

using namespace std;
void write_image(const char* name,float* pimg,int wt,int ht);
void read_image(const char* name,float** ppimg,int * pwt,int* pht);
void cpu_to_gpu(band_info* pcin,int num_bands,band_info** ppcout,int copy=1);
void gpu_release_images(band_info** ppbands,int num_bands);
void gpu_to_cpu(band_info* pcin,int num_bands,band_info** ppcout,int copy=1);
void callback_c1_baseline(band_info*,int, band_info*,int,band_info** ,int* );
void cpu_create_c0(float* pimg,int width,int height,band_info** ppc,int* pbands);
void cpu_load_filters(const char* filename,band_info** ppfilt,int* pnfilts);
__global__  void kernel_s_norm_filter(band_info* filters,band_info* s,int band,int blockrows);
__global__  void kernel_c_generic(band_info* d_outbands,int b,float scalex,float scaley,int pool_xy,int blockrows);
__global__  void kernel_s_exp_tuning(band_info* filters,band_info* s,int band,int blockrows);

/*
image texture
*/
texture<float,2,cudaReadModeElementType> teximg;
texture<float,2,cudaReadModeElementType> texfilt;

__device__ float* elptr(float* base,int depth,int row,int col,int height,int pitch)
{
	return (float*)((char*)base+depth*height*pitch+row*pitch)+col;
}

void gpu_to_cpu(band_info* pcin,int num_bands,band_info** ppcout,int copy)
{
	*ppcout				= new band_info[num_bands]; /*final*/
	band_info* hband	= new band_info[num_bands]; /*staging*/
	/*copy structure*/
	CUDA_SAFE_CALL(cudaMemcpy(hband,pcin,sizeof(band_info)*num_bands,cudaMemcpyDeviceToHost));
	assert(*ppcout);
	assert(hband);

	for(int i=0;i<num_bands;i++)
	{
		band_info* pcout	=	*ppcout+i;	
		float*     cpuptr	=	NULL;
		size_t     pitch	=	0;
		pcout->depth		=	hband[i].depth;
		pcout->height		=	hband[i].height;
		pcout->width		=	hband[i].width;										
		/*copy*/
		if(copy)
		{
			/*allocate memory*/
			cpuptr		 = new float[hband[i].height*hband[i].width*hband[i].depth];
			CUDA_SAFE_CALL(cudaMemcpy2D(cpuptr,hband[i].width*sizeof(float),
						 hband[i].ptr,hband[i].pitch,
						 hband[i].width*sizeof(float),hband[i].height*hband[i].depth,
						 cudaMemcpyDeviceToHost));
			pcout->ptr   = cpuptr;
			pcout->pitch = hband[i].width*sizeof(float);
		}
		else
		{
			pcout->ptr	 = NULL;
			pcout->pitch = 0;
		}
		
	}
	delete[] hband;
}


void cpu_to_gpu(band_info* pcin,int num_bands,band_info** ppcout,int copy)
{
	band_info* hband = new band_info[num_bands];
	/*stage the structure in the host*/
	for(int i=0;i<num_bands;i++)
	{
		band_info* pcout	= hband+i;	
		float*     gpuptr	= NULL;
		size_t     pitch	= 0;
		pcout->depth		= pcin[i].depth;
		pcout->height		= pcin[i].height;
		pcout->width		= pcin[i].width;										
		if(copy)
		{
			/*allocate space*/
			CUDA_SAFE_CALL(cudaMallocPitch((void**)&gpuptr,&pitch,
											pcin[i].width*sizeof(float),
											pcin[i].height*pcin[i].depth));
			/*copy*/
			CUDA_SAFE_CALL(cudaMemcpy2D(gpuptr,pitch,
										pcin[i].ptr,pcin[i].pitch,
										pcin[i].width*sizeof(float),pcin[i].height*pcin[i].depth,
										cudaMemcpyHostToDevice));
			pcout->ptr   = gpuptr;
			pcout->pitch = pitch;
		}
		else
		{
			pcout->ptr   = NULL; /*NEVER USE THIS*/
			pcout->pitch = 0;
		}
	}
	/*copy onto the gpu*/
	CUDA_SAFE_CALL(cudaMalloc((void**)ppcout,num_bands*sizeof(band_info)));
	CUDA_SAFE_CALL(cudaMemcpy(*ppcout,hband,num_bands*sizeof(band_info),cudaMemcpyHostToDevice));
	delete[] hband;
}

void gpu_release_images(band_info** ppbands,int num_bands)
{
	band_info* hbands = new band_info[num_bands]; /*staging*/
	assert(hbands);
	/*copy structure*/
	CUDA_SAFE_CALL(cudaMemcpy(hbands,*ppbands,sizeof(band_info)*num_bands,cudaMemcpyDeviceToHost));
	assert(*ppbands);
	for(int i=0;i<num_bands;i++)
	{
		band_info* pband = hbands+i;	
		void* ptr		 = pband->ptr;
		if(ptr)	cudaFree(ptr);
	}
	delete[] hbands;
	cudaFree(*ppbands);
}


__global__ void kernel_c_generic(band_info* d_outbands,int b,float dx,float dy,int pool_xy,int blockrows)
{
	int depth     = blockIdx.x;
	int c_depth   = d_outbands[b].depth;
	int c_height  = d_outbands[b].height;
	int c_width	  = d_outbands[b].width;
	int c_pitch   = d_outbands[b].pitch;
	int row_start = threadIdx.x*blockrows;
	int row_end   = row_start+blockrows;
	int	bound     = pool_xy/2;
	float pixval  = 0;

	for(int row=row_start;row<row_end && row<c_height;row++)
	{
		float    cy   =  (float)(row+c_height*depth)/(c_height*c_depth);
		if(row< bound || row>= c_height-bound) continue;
		for(int col=bound;col< c_width-bound;col++)
		{
			float* outptr = elptr(d_outbands[b].ptr,depth,row,col,c_height,c_pitch);
			float  maxval = *outptr;
			/*get maximum*/
			float    cx   =  (float)col/c_width;
			for(int u=-bound;u<=bound;u++)
			{
				for(int v=-bound;v<=bound;v++)
				{
					pixval		 = tex2D(teximg,cx+u*dx,cy+v*dy);
					maxval       = fmaxf(maxval,pixval);
				}/*end v*/
			}/*end u*/
			*outptr= pixval;
		}/*end col*/
	}/*end row*/
}

void gpu_c_generic(
		IN  band_info* sin,     /*pointer to DEVICE storage*/
		IN  int in_bands,     /*number of input bands*/
		IN  int pool_xy,      /*spatial pooling: subsampling by pool_xy/2*/
		IN  int pool_scale,   /*scale wise pooling: out_bands=in_bands/pool_scale*/
		OUT band_info** ppc,      /*pointer to DEVICE storage*/
		OUT int	*pout_bands   /*number of output bands*/
	)
{
   cudaArray*				gpu_img_array;
   band_info*				d_outbands;
   band_info*				h_outbands;
   float*					d_ptr;
   size_t					d_pitch;
   int i,o,b;

   int out_bands = in_bands/pool_scale;
   *pout_bands   = out_bands;

   /*stage output*/
   h_outbands = new band_info[out_bands];
   int srate  = pool_xy/2; 
   for(i=0,o=0;i<in_bands;i+=pool_scale,o++)
   {
		h_outbands[o].height = sin[i].height/srate;
		h_outbands[o].width  = sin[i].width/srate;
		h_outbands[o].depth  = sin[i].depth;
		CUDA_SAFE_CALL(cudaMallocPitch((void**)&d_ptr,&d_pitch,h_outbands[o].width*sizeof(float),h_outbands[o].depth*h_outbands[o].height));
		CUDA_SAFE_CALL(cudaMemset2D(d_ptr,d_pitch,0,h_outbands[o].width*sizeof(float),h_outbands[o].depth*h_outbands[o].height));
		h_outbands[o].pitch = d_pitch;
		h_outbands[o].ptr   = d_ptr;
   }
   CUDA_SAFE_CALL(cudaMalloc((void**)&d_outbands,out_bands*sizeof(band_info)));
   CUDA_SAFE_CALL(cudaMemcpy(d_outbands,h_outbands,out_bands*sizeof(band_info),cudaMemcpyHostToDevice));

  
   /*copy image*/ 
   for(b=0;b<in_bands;b++)
   {
	   cudaChannelFormatDesc	imgdesc=cudaCreateChannelDesc<float>();
	   CUDA_SAFE_CALL(cudaMallocArray(&gpu_img_array,&imgdesc,sin[b].width,sin[b].height*sin[b].depth));
		/*bind the texture*/
		teximg.addressMode[0] = cudaAddressModeClamp;
	    teximg.addressMode[1] = cudaAddressModeClamp;
	    teximg.filterMode     = cudaFilterModePoint; //take note//
	    teximg.normalized     = true;//take note//
		/*copy to array*/
		CUDA_SAFE_CALL(cudaMemcpy2DToArray(gpu_img_array,0,0,
										   sin[b].ptr,sin[b].pitch,
										   sin[b].width*sizeof(float),sin[b].height*sin[b].depth,
									       cudaMemcpyHostToDevice));
	    CUDA_SAFE_CALL(cudaBindTextureToArray(teximg,gpu_img_array));
		
		/*call the kernel*/
		o				 = b/pool_scale;
		uint3 gridsz	 = make_uint3(sin[b].depth,1,1);
		int   nthreads	 = min(h_outbands[o].height,MAXTHREADS);
		int   blockrows  = ceilf((float)h_outbands[o].height/nthreads);
		uint3 blocksz	 = make_uint3(nthreads,1,1);
		float dx	     = 1.0f/sin[b].width;
		float dy		 = 1.0f/(sin[b].height*sin[b].depth);
		kernel_c_generic<<<gridsz,blocksz>>>(d_outbands,o,dx,dy,pool_xy,blockrows);
		CUDA_SAFE_CALL(cudaThreadSynchronize());
		CUDA_SAFE_CALL(cudaUnbindTexture(teximg));						   
		CUDA_SAFE_CALL(cudaFreeArray(gpu_img_array));
   }
   
   /*copy image to output*/   
   gpu_to_cpu(d_outbands,out_bands,ppc);
   /*clean up*/
   delete [] h_outbands;
   gpu_release_images(&d_outbands,out_bands);
}


void cpu_release_images(band_info** ppbands,int num_bands)
{
	for(int i=0;i<num_bands;i++)
	{
		delete[] (*ppbands)[i].ptr;
	}
	delete [] *ppbands;
	*ppbands = NULL;
}

void cpu_create_c0(float* pimg,int width,int height,band_info** ppc,int* pbands)
{
	const int	num_scales = 16;
	const float scale	   = 1.121;
	*ppc				   = new band_info[num_scales];
	assert(*ppc!=NULL);
	*pbands				   = num_scales;
	float		curr_scale = 1;
	for(int b=0;b<num_scales;b++,curr_scale*=scale)
	{
		int bht			= floorf(height/curr_scale);
		int bwt			= floorf(width/curr_scale);
		band_info* pc	= *ppc+b;
		pc->height		= bht;
		pc->width		= bwt;
		pc->pitch		= bwt*sizeof(float);
		pc->depth		= 1;
		pc->ptr			= new float[bht*bwt];
		assert(pc->ptr!=NULL);
		for(int x=0;x<bwt;x++)
		{
			for(int y=0;y<bht;y++)
			{
				float sx = x*curr_scale;
				float sy = y*curr_scale;
				int   fx = floorf(sx); int  cx = ceilf(sx);
				int   fy = floorf(sy); int  cy = ceilf(sy);
				float xalpha=sx-fx;
				float yalpha=sy-fy;
				float val   =pimg[fx+fy*width]*(1-xalpha)*(1-yalpha)+
							 pimg[cx+fy*width]*(xalpha)*(1-yalpha)+
							 pimg[fx+cy*width]*(1-xalpha)*(yalpha)+
							 pimg[cx+cy*width]*(xalpha)*(yalpha);
				pc->ptr[y*bwt+x]=val;
			}
		}
	}
}

void cpu_load_filters(const char* filename,band_info** ppfilt,int* pnfilts)
{
	ifstream fin(filename);
	/*read number of filters*/
	int num_filters;
	fin>>num_filters;
	cout<<"Number of filters"<<num_filters<<endl;
	assert(num_filters >= 1);
	*pnfilts= num_filters;
	*ppfilt = new band_info[num_filters];
	assert(*ppfilt !=NULL);

	for(int i=0;i<num_filters;i++)
	{
		band_info* pfilt = *ppfilt+i;
		int d			=0;
		
		fin >> pfilt->depth;
		if(d==0)
		{
			fin >> pfilt->height;
			fin >> pfilt->width;
		}
		/*allocate memory for the image*/
		pfilt->pitch=pfilt->width*sizeof(float);
		pfilt->ptr  =new float[pfilt->depth*pfilt->height*pfilt->width];
		assert(pfilt->ptr);
		for(;d<pfilt->depth;d++)
		{
			if(d!=0)
			{
				int dummy;
				fin>>dummy; /*height*/
				fin>>dummy; /*width*/
			}
			float* ptr=pfilt->ptr+d*pfilt->height*pfilt->width;
			for(int y=0;y<pfilt->height;y++)
			{
				for(int x=0;x<pfilt->width;x++)
					fin>>ptr[y*pfilt->width+x];
			}
		}
	}
	fin.close();
}




/*
put the image into texture memory
put the filter into global memory
call the kernel for each band of the input (maybe change later)
*/
void gpu_s_norm_filter(band_info* cin,int in_bands,band_info* filt,int num_filt, band_info** pps, int *out_bands)
{
   cudaArray*				gpu_img_array;
   band_info*				d_outbands;
   band_info*				h_outbands;
   band_info*				d_filts;
   float*					d_ptr;
   size_t					d_pitch;
   /*channel description*/
   
   /*stage output*/
   h_outbands = new band_info[in_bands];
   for(int b=0;b<in_bands;b++)
   {
		h_outbands[b].height = cin[b].height;
		h_outbands[b].width  = cin[b].width;
		h_outbands[b].depth  = num_filt;
		CUDA_SAFE_CALL(cudaMallocPitch((void**)&d_ptr,&d_pitch,cin[b].width*sizeof(float),num_filt*cin[b].height));
		CUDA_SAFE_CALL(cudaMemset2D(d_ptr,d_pitch,0,cin[b].width*sizeof(float),num_filt*cin[b].height));
		h_outbands[b].pitch = d_pitch;
		h_outbands[b].ptr   = d_ptr;
   }
   CUDA_SAFE_CALL(cudaMalloc((void**)&d_outbands,in_bands*sizeof(band_info)));
   CUDA_SAFE_CALL(cudaMemcpy(d_outbands,h_outbands,in_bands*sizeof(band_info),cudaMemcpyHostToDevice));
   *out_bands= in_bands;
	   
   /* transfer filters*/
   cpu_to_gpu(filt,num_filt,&d_filts);
  
   /*copy image*/ 
   cudaChannelFormatDesc	imgdesc=cudaCreateChannelDesc<float>();
   CUDA_SAFE_CALL(cudaMallocArray(&gpu_img_array,&imgdesc,cin[0].width,cin[0].height*cin[0].depth));
   for(int b=0;b<in_bands;b++)
   {
		/*bind the texture*/
		teximg.addressMode[0] = cudaAddressModeClamp;
	    teximg.addressMode[1] = cudaAddressModeClamp;
	    teximg.filterMode     = cudaFilterModePoint;
	    teximg.normalized     = false;
		/*copy to array*/
		CUDA_SAFE_CALL(cudaMemcpy2DToArray(gpu_img_array,0,0,
										   cin[b].ptr,cin[b].pitch,
										   cin[b].width*sizeof(float),cin[b].height*cin[b].depth,
									       cudaMemcpyHostToDevice));
	    CUDA_SAFE_CALL(cudaBindTextureToArray(teximg,gpu_img_array));
		/*call the kernel*/
		int   nthreads	 = min(cin[b].height,MAXTHREADS);
		int   blockrows  = ceilf((float)cin[b].height/nthreads);
		uint3 gridsz	 = make_uint3(num_filt,1,1);
		uint3 blocksz	 = make_uint3(nthreads,1,1);
		kernel_s_norm_filter<<<gridsz,blocksz>>>(d_filts,d_outbands,b,blockrows);
	    CUDA_SAFE_CALL(cudaUnbindTexture(teximg));						   
   }
   CUDA_SAFE_CALL(cudaThreadSynchronize());
   /*copy image to output*/   
   gpu_to_cpu(d_outbands,*out_bands,pps);
   /*clean up*/
   delete [] h_outbands;
   CUDA_SAFE_CALL(cudaFreeArray(gpu_img_array));
   gpu_release_images(&d_outbands,in_bands);
   gpu_release_images(&d_filts,num_filt);
}


__global__  void kernel_s_norm_filter(band_info* filters,band_info* s,int band,int blockrows)
{
	__shared__ float sfilt[1024];
	/*load the filter into shared memory*/
	band_info 	filt_curr		=filters[blockIdx.x];
	int			filt_pitch		=filt_curr.pitch;
	int			filt_width		=filt_curr.width;
	int			filt_height		=filt_curr.height;
	int			filt_depth		=filt_curr.depth;
	int			s_height		=s[band].height;
	int			s_width			=s[band].width;
	int			s_pitch			=s[band].pitch;

	float		*inptr,*outptr;
	int			depth			= 0;
	int			col				= 0;
	int			row_start		=threadIdx.x*blockrows;
	int			row_end			=row_start+blockrows;
    int			row				=row_start;
	int x,y,u,v;

	for(row = row_start;row<filt_height && row<row_end;row++)
	{
		for(depth=0;depth<filt_depth;depth++)
		{
			for(col=0;col<filt_width;col++)
			{
				inptr  		= elptr(filt_curr.ptr,depth,row,col,filt_height,filt_pitch);
				outptr		= elptr(sfilt,depth,row,col,filt_height,filt_width*sizeof(float));
				*outptr		= *inptr;
			}	
		}
	}
	__syncthreads();
	int  bound = filt_width/2;
	for(row = row_start;row< s_height&& row<row_end;row++)
	{
		/*compute response for a single row of output*/
		if(row<bound || row>= s_height-bound)
			continue;
		outptr			=	elptr(s[band].ptr,blockIdx.x,row,0,s_height,s_pitch);
		for(col=0;col<bound;col++)
			outptr[col]=0;
		for(col=bound;col<s_width-bound;col++)
		{
			float num      = 0.0f;
			float denimg   = 0.01f;
			for(depth=0;depth<1;depth++)
			{
				for(u=0;u<filt_width;u++)
				{
					for(v=0;v<filt_height;v++)
					{
						float  pixval  = tex2D(teximg,col+u-bound,s_height*depth+row+v-bound);
						float* pfiltval= elptr(sfilt,depth,v,u,filt_height,filt_width*sizeof(float));
						num+=  (*pfiltval)*pixval;
						denimg+= pixval*pixval;
					}/*end y*/
				}/*end x*/
			}/*end depth*/
			float outval= fabsf(num)/(0.01f+sqrtf(denimg));
			outptr[col] = outval;//fminf(1,outval);
		}/*end col*/
		for(col=s_width-bound;col<s_width;col++)
			outptr[col]=0;
	}/*end row*/
	__syncthreads();
}

void gpu_s_exp_tuning(band_info* cin,int in_bands,band_info* filt,int num_filt,OUT band_info** pps,int*out_bands)
{
   cudaArray*				gpu_img_array;
   band_info*				d_outbands;
   band_info*				h_outbands;
   band_info*				d_filts;
   float*					d_ptr;
   size_t					d_pitch;
   /*channel description*/
   
   /*stage output*/
   h_outbands = new band_info[in_bands];
   for(int b=0;b<in_bands;b++)
   {
		h_outbands[b].height = cin[b].height;
		h_outbands[b].width  = cin[b].width;
		h_outbands[b].depth  = num_filt;
		CUDA_SAFE_CALL(cudaMallocPitch((void**)&d_ptr,&d_pitch,cin[b].width*sizeof(float),num_filt*cin[b].height));
		CUDA_SAFE_CALL(cudaMemset2D(d_ptr,d_pitch,0,cin[b].width*sizeof(float),num_filt*cin[b].height));
		h_outbands[b].pitch = d_pitch;
		h_outbands[b].ptr   = d_ptr;
   }
   CUDA_SAFE_CALL(cudaMalloc((void**)&d_outbands,in_bands*sizeof(band_info)));
   CUDA_SAFE_CALL(cudaMemcpy(d_outbands,h_outbands,in_bands*sizeof(band_info),cudaMemcpyHostToDevice));
   *out_bands= in_bands;
	   
   /* transfer filters*/
   cpu_to_gpu(filt,num_filt,&d_filts);
  
   /*copy image*/ 
   cudaChannelFormatDesc	imgdesc=cudaCreateChannelDesc<float>();
   CUDA_SAFE_CALL(cudaMallocArray(&gpu_img_array,&imgdesc,cin[0].width,cin[0].height*cin[0].depth));
   for(int b=0;b<in_bands;b++)
   {
		/*bind the texture*/
		teximg.addressMode[0] = cudaAddressModeClamp;
	    teximg.addressMode[1] = cudaAddressModeClamp;
	    teximg.filterMode     = cudaFilterModePoint;
	    teximg.normalized     = false;
		/*copy to array*/
		CUDA_SAFE_CALL(cudaMemcpy2DToArray(gpu_img_array,0,0,
										   cin[b].ptr,cin[b].pitch,
										   cin[b].width*sizeof(float),cin[b].height*cin[b].depth,
									       cudaMemcpyHostToDevice));
	    CUDA_SAFE_CALL(cudaBindTextureToArray(teximg,gpu_img_array));
		/*call the kernel*/
		int   nthreads	 = min(cin[b].height,MAXTHREADS);
		int   blockrows  = ceilf((float)cin[b].height/nthreads);
		uint3 gridsz	 = make_uint3(num_filt,1,1);
		uint3 blocksz	 = make_uint3(nthreads,1,1);
		kernel_s_exp_tuning<<<gridsz,blocksz>>>(d_filts,d_outbands,b,blockrows);
	    CUDA_SAFE_CALL(cudaUnbindTexture(teximg));						   
   }
   CUDA_SAFE_CALL(cudaThreadSynchronize());
   /*copy image to output*/   
   gpu_to_cpu(d_outbands,*out_bands,pps);
   /*clean up*/
   delete [] h_outbands;
   CUDA_SAFE_CALL(cudaFreeArray(gpu_img_array));
   gpu_release_images(&d_outbands,in_bands);
   gpu_release_images(&d_filts,num_filt);
}


__global__ void kernel_s_exp_tuning(band_info* filters,band_info* s,int band,int blockrows)
{
	__shared__ float sfilt[1024];
	/*load the filter into shared memory*/
	band_info 	filt_curr		=filters[blockIdx.x];
	int			filt_pitch		=filt_curr.pitch;
	int			filt_width		=filt_curr.width;
	int			filt_height		=filt_curr.height;
	int			filt_depth		=filt_curr.depth;
	int			s_height		=s[band].height;
	int			s_width			=s[band].width;
	int			s_pitch			=s[band].pitch;

	float		*inptr,*outptr;
	int			depth			= 0;
	int			col				= 0;
	int			row_start		=threadIdx.x*blockrows;
	int			row_end			=row_start+blockrows;
    int			row				=row_start;
	int x,y,u,v;

	for(row = row_start;row<filt_height && row<row_end;row++)
	{
		for(depth=0;depth<filt_depth;depth++)
		{
			for(col=0;col<filt_width;col++)
			{
				inptr  		= elptr(filt_curr.ptr,depth,row,col,filt_height,filt_pitch);
				outptr		= elptr(sfilt,depth,row,col,filt_height,filt_width*sizeof(float));
				*outptr		= *inptr;
			}	
		}
	}
	__syncthreads();
	int  bound = filt_width/2;
	for(row = row_start;row< s_height&& row<row_end;row++)
	{
		/*compute response for a single row of output*/
		if(row<bound || row>= s_height-bound)
			continue;
		outptr			=	elptr(s[band].ptr,blockIdx.x,row,0,s_height,s_pitch);
		for(col=0;col<bound;col++)
			outptr[col]=0;
		for(col=bound;col<s_width-bound;col++)
		{
			float num      = 0.0f;
			float den      = 0.01f;
			for(depth=0;depth<1;depth++)
			{
				for(u=0;u<filt_width;u++)
				{
					for(v=0;v<filt_height;v++)
					{
						float  pixval  = tex2D(teximg,col+u-bound,s_height*depth+row+v-bound);
						float* pfiltval= elptr(sfilt,depth,v,u,filt_height,filt_width*sizeof(float));
						num+=  ((*pfiltval)-pixval)*((*pfiltval)-pixval);
						den+= (*pfiltval)*(*pfiltval);
					}/*end y*/
				}/*end x*/
			}/*end depth*/
			float sigma = sqrtf(den)*0.33;
			sigma       = 2*sigma*sigma;
			float outval= expf(-num/sigma);
			outptr[col] = outval;//fminf(1,outval);
		}/*end col*/
		for(col=s_width-bound;col<s_width;col++)
			outptr[col]=0;
	}/*end row*/
	__syncthreads();
}

void cpu_c_terminal(
	IN band_info* s,      /*pointer to device storage*/
	IN int in_bands,      /*number of input bands*/
	OUT float** ppc,          /*pointer to DEVICE storage*/
	OUT int* out_units   /*=input depth*/	
)
{
	*out_units = s[0].depth;
	*ppc       = new float[*out_units];
	assert(*ppc);
	
	float* pc  = *ppc;
	memset(pc,0,sizeof(float)*(*out_units));

	for(int d=0;d<s[0].depth;d++)
	{
		for(int b=0;b<in_bands;b++)
		{
			int    numel  = s[b].height*s[b].width;
			float* ptr    = s[b].ptr+d*numel;
			float* pmaxval= max_element(ptr,ptr+numel);
			pc[d]         = max(*pmaxval,pc[d]);
		}
	}
}


void callback_c1_baseline(band_info* cin,int ncin, band_info* filts,int nfilts,band_info** ppcout,int* pncout)
{
	band_info* sout;
	int        nsout;
	gpu_s_norm_filter(cin,ncin,filts,nfilts,&sout,&nsout);
	//gpu_s_norm_filter(cin,ncin,filts,nfilts,ppcout,pncout);
	gpu_c_generic(sout,nsout,8,2,ppcout,pncout);
	cpu_release_images(&sout,nsout);
}

void callback_c2_baseline(band_info* cin,int ncin,
						  band_info* c0filts,int nc0filts,
						  band_info* c1filts,int nc1filts,
						  band_info** ppcout,int* pncout)
{
	band_info	*s1,*c1,*s2;
	int         ns1,nc1,ns2;
	gpu_s_norm_filter(cin,ncin,c0filts,nc0filts,&s1,&ns1);
	gpu_c_generic(s1,ns1,8,2,&c1,&nc1);
	gpu_s_exp_tuning(c1,nc1,c1filts,nc1filts,&s2,&ns2);
	gpu_c_generic(s2,ns2,5,2,ppcout,pncout);

	cpu_release_images(&s1,ns1);
	cpu_release_images(&c1,nc1);
	cpu_release_images(&s2,ns2);
}

void callback_c2b_baseline(band_info* cin,int ncin,
						  band_info* c0filts,int nc0filts,
						  band_info* c1filts,int nc1filts,
						  float** ppc2b,int* nc2b)
{
	band_info	*s1,*c1,*s2;
	int         ns1,nc1,ns2;
	gpu_s_norm_filter(cin,ncin,c0filts,nc0filts,&s1,&ns1);
	gpu_c_generic(s1,ns1,8,2,&c1,&nc1);
	gpu_s_exp_tuning(c1,nc1,c1filts,nc1filts,&s2,&ns2);
	cpu_c_terminal(s2,ns2,ppc2b,nc2b);
	
	//cpu_c_terminal(c1,nc1,ppc2b,nc2b);
	cpu_release_images(&s1,ns1);
	cpu_release_images(&c1,nc1);
	cpu_release_images(&s2,ns2);
}